#!/bin/bash
#=================================================================================
# Test edge image type rhel-edge-commit on rhel 8.4
#
# 1. prepare test environment
# 2. create blueprint
# 3. compose edge image of type rhel-edge-commit
# 4. download edge image
# 5. install/upgrade edge image
# 6. run test cases
# 7. cleanup test environment
#
# @Author yih@redhat.com
# @Date: 3/26/2021
#=================================================================================
set -uo pipefail
. ./common/vars.sh
. ./common/utils.sh

source /etc/os-release

#Define general vars
TEST_UUID=$(uuidgen)
TEMP_DIR=$(mktemp -d)
ARCH=$(uname -m)

#Define compose log files
COMPOSE_START_FILE=${TEMP_DIR}/${TEST_UUID}_start.json
COMPOSE_INFO_FILE=${TEMP_DIR}/${TEST_UUID}_info.json

#Define variables for generated file name
BLUEPRINT_INSTALL_FILE=${TEMP_DIR}/blueprint_install.toml
BLUEPRINT_UPGRADE_FILE=${TEMP_DIR}/blueprint_upgrade.toml
KS_FILE=${TEMP_DIR}/ks.cfg
NETWORK_FILE=${TEMP_DIR}/integration.xml

##Define os vars
OSTREE_REF="rhel/8/${ARCH}/edge"

##Define ansible vars
ANSIBLE_INVENTORY_FILE=${TEMP_DIR}/inventory

# Prepare the test environment
function before_test {
    greenprint "===>Before test, prepare test env"
    # Install epel repo for ansible
    sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
    # Customize repository
    sudo mkdir -p /etc/osbuild-composer/repositories
    sudo cp files/rhel-8-4-0.json /etc/osbuild-composer/repositories/rhel-8-beta.json

    # Install required packages
    greenprint "    Installing required packages"
    sudo dnf install -y --nogpgcheck osbuild-composer composer-cli cockpit-composer ansible bash-completion httpd jq expect qemu-img qemu-kvm libvirt-client libvirt-daemon-kvm virt-install

    # Start osbuild-composer.socket
    greenprint "    Starting osbuild-composer.socket"
    sudo systemctl enable --now osbuild-composer.socket

    # Start libvirtd and test it.
    greenprint "    Starting libvirt daemon"
    sudo systemctl start libvirtd
    sudo virsh list --all > /dev/null

    greenprint "    Starting network integration(for edge image later use)"
    _gen_network_file
    if ! sudo virsh net-info integration > /dev/null 2>&1; then
    sudo virsh net-define "$NETWORK_FILE"
    fi

    if [[ `virsh net-info integration|grep Active` == *no* ]]; then
    sudo virsh net-start integration
    fi

    # Allow anyone in the wheel group to talk to libvirt.
    greenprint "    Allowing users in wheel group to talk to libvirt"
    WHEEL_GROUP=wheel
    if [[ $ID == rhel ]]; then
      WHEEL_GROUP=adm
    fi
    _gen_libvirt_rule

    # Start http service
    greenprint "    Starting http service"
    sudo systemctl start httpd.service
}

# Create blueprints for install/upgrade and push to compose
function create_blueprint {
    greenprint "===>Create blueprint"
    case "${1}" in
      "upgrade")
          blue_print_name="upgrade-rhel-edge-commit"
          greenprint "    Creating blueprint file to ${1} rhel-edge-commit: ${BLUEPRINT_UPGRADE_FILE}"
          _gen_bp_of_upgrade "${blue_print_name}"
          composer-cli blueprints push "${BLUEPRINT_UPGRADE_FILE}";;
      "install")
          blue_print_name="install-rhel-edge-commit"
          greenprint "    Creating blueprint file to ${1} rhel-edge-commit: ${BLUEPRINT_INSTALL_FILE}"
          _gen_bp_of_install "${blue_print_name}"
          composer-cli blueprints push "${BLUEPRINT_INSTALL_FILE}";;
      *)
          greenprint "    Invalid options, should be install or upgrade, exit testing!"
          exit 1;;
    esac

    tmpResult=$(composer-cli blueprints list|grep "${blue_print_name}")
    if [[ $tmpResult =~ ${blue_print_name} ]]
    then
      greenprint "    Successfully pushed blueprint <${blue_print_name}> to composer."
    else
      greenprint "    Failed to push blueprint <${blue_print_name}> to composer."
      exit 1
    fi
}

# Compose images for install/upgrade
function compose_image {
    greenprint "===>Compose edge image"
    COMPOSE_START_FILE=${TEMP_DIR}/${TEST_UUID}_start.log
    COMPOSE_INFO_FILE=${TEMP_DIR}/${TEST_UUID}_info.log

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!

    case "${1}" in
      "upgrade")
          greenprint "    Composing edge image of type rhel-edge-commit for $1."
          sudo composer-cli --json compose start-ostree "${blue_print_name}" rhel-edge-commit --ref "$OSTREE_REF" --parent "$INSTALL_HASH" | tee "$COMPOSE_START_FILE";;
      "install")
          greenprint "    Composing edge image of type rhel-edge-commit for $1."
          sudo composer-cli --json compose start-ostree "${blue_print_name}" rhel-edge-commit | tee "$COMPOSE_START_FILE";;
      *)
          greenprint "    Invalid options, should be install or upgrade, exit testing!"
          exit 1;;
    esac

    COMPOSE_ID=$(jq -r '.build_id' "$COMPOSE_START_FILE")
    if [[ ${COMPOSE_ID} == null ]]; then
    greenprint "    Compose command is rejected by composer, please check log $COMPOSE_START_FILE."
    exit 1
    fi
    greenprint "    Image $COMPOSE_ID is in the process of composing, waiting for it to complete."
    _wait_compose_finish "${COMPOSE_ID}"

    sudo kill ${WORKER_JOURNAL_PID}
}

# Download install/upgrade images and prepare the edge repo
function download_image {
    greenprint "===>Download edge image"
    case "${1}" in
      "upgrade")
          greenprint "    Downloading image of type rhel-edge-commit for $1."
          sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
          IMAGE_FILENAME="${COMPOSE_ID}-commit.tar"
          UPGRADE_PATH="$(pwd)/upgrade"
          mkdir -p "$UPGRADE_PATH"
          sudo tar -xf "$IMAGE_FILENAME" -C "$UPGRADE_PATH"
          greenprint "    Pulling new ostree commit into ${HTTPD_PATH}/repo."
          sudo ostree pull-local --repo "${HTTPD_PATH}/repo" "${UPGRADE_PATH}/repo" "$OSTREE_REF"
          sudo ostree summary --update --repo "${HTTPD_PATH}/repo";;
      "install")
          greenprint "    Downloading image of type rhel-edge-commit for $1."
          sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
          IMAGE_FILENAME="${COMPOSE_ID}-commit.tar"
          greenprint "    Extracting commit tar file to ${HTTPD_PATH}."
          sudo tar -xf "$IMAGE_FILENAME" -C ${HTTPD_PATH};;
      *)
          greenprint "    Invalid options, should be install or upgrade, exit testing!"
          exit 1;;
    esac

    # Ensure SELinux is happy with all objects files.
    greenprint "    Running restorecon on web server root folder"
    sudo restorecon -Rv "${HTTPD_PATH}/repo" > /dev/null
}

# Install edge image
function install_image {
    greenprint "===>Install edge image"
    INSTALL_HASH=$(jq -r '."ostree-commit"' ${HTTPD_PATH}/compose.json)
    greenprint "    Fetching edge commit hash: $INSTALL_HASH "
    IMAGE_KEY=${INSTALL_HASH}
    greenprint "    Creating qcow2 disk to install edge image"
    LIBVIRT_IMAGE_PATH=/var/lib/libvirt/images/${INSTALL_HASH}.qcow2
    sudo qemu-img create -f qcow2 "${LIBVIRT_IMAGE_PATH}" 20G
    greenprint "    Generating kickstart file at ${KS_FILE}"
    _gen_ks_file "${IMAGE_TYPE_COMMIT}"
    greenprint "    Installing edge image via anaconda."
    sudo virt-install  --initrd-inject="${KS_FILE}" \
                     --extra-args="ks=file:/ks.cfg console=ttyS0,115200" \
                     --name="${IMAGE_KEY}"\
                     --disk path="${LIBVIRT_IMAGE_PATH}",format=qcow2 \
                     --ram 3072 \
                     --vcpus 2 \
                     --network network=integration,mac=34:49:22:B0:83:30 \
                     --os-type linux \
                     --os-variant ${RHEL_84_VARIANT} \
                     --location ${BOOT_LOCATION} \
                     --nographics \
                     --noautoconsole \
                     --wait=-1 \
                     --noreboot
    greenprint "    Starting edge image vm if not started"
    sudo virsh start "${IMAGE_KEY}"
}

# Upgrade edge image
function upgrade_image {
    greenprint "===>Upgrade edge image of type rhel-edge-commit"
    UPGRADE_HASH=$(jq -r '."ostree-commit"' < "${UPGRADE_PATH}"/compose.json)
    greenprint "    Fetching upgrade hash: $UPGRADE_HASH"
    greenprint "    Upgrading ostree image/commit"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${GUEST_ADDRESS} 'sudo rpm-ostree upgrade'
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${GUEST_ADDRESS} 'nohup sudo systemctl reboot &>/dev/null & exit'
    sleep 10
}

# Do a quick check of edge image status, make sure can ssh to it and the
# packages specified in install/upgrade blueprints is installed as expected.
function check_vm_status {
    greenprint "===>Check if edge image system."
    _wait_ssh_ok "${GUEST_ADDRESS}"

    if [[ $1 == install ]]; then
    greenprint "    For fresh install, check if python36 pkg is installed.."
    insResult=$(_is_pkg_installed "python36")
    if [[ $insResult == 0 ]]
    then
      greenprint "    Assert success: Found python36 package in edge image."
    else
      greenprint "    Assert failure: Failed to find python36 package in edge image."
      exit 1
    fi
    elif [[ $1 == upgrade ]]; then
    greenprint "    For upgrade, check if wget pkg is installed."
    ugdResult=$(_is_pkg_installed "wget")
    if [[ $ugdResult == 0 ]]
    then
      greenprint "    Assert success: Found wget package in edge image."
    else
      greenprint "    Assert failure: upgrade didn't get the expected result."
      exit 1
    fi
    else
    greenprint "    Invalid options, should be install or upgrade, exit testing!"
    exit 1
    fi
}

# Run test cases defined in ansible playbook
function run_ansbile_playbook {
    greenprint "===>Run ansible playbook to test edge"
    TEST_RESULT=0
    _gen_ansible_inventory
    sudo ansible-playbook -v -i $ANSIBLE_INVENTORY_FILE -e image_type=${IMAGE_TYPE_COMMIT} -e ostree_commit="${UPGRADE_HASH}" check_ostree.yml || TEST_RESULT=1
    if [[ ${TEST_RESULT} == 1 ]]; then
        greenprint "    There are failures in ansible test results, exit testing!"
        exit 1
    fi
}

# Clean up test environment
function after_test {
    greenprint "===>After test, clean up test env"
    greenprint "    Delete edge vm"
    sudo virsh destroy "${IMAGE_KEY}"
    if [[ $ARCH == aarch64 ]]; then
        sudo virsh undefine "${IMAGE_KEY}" --nvram
    else
        sudo virsh undefine "${IMAGE_KEY}"
    fi
    # Remove image file
    greenprint "    Delete edge image file"
    sudo rm -f "$IMAGE_FILENAME"
    # Remove qcow2 file.
    greenprint "    Delete qcow2 disk file"
    sudo rm -f "$LIBVIRT_IMAGE_PATH"
    # Remove extracted upgrade image-tar.
    greenprint "    Delete repo of install/upgrade"
    sudo rm -rf "$UPGRADE_PATH"
    sudo rm -rf "${HTTPD_PATH}"/{repo,compose.json}
    greenprint "    Delete temp directory"
    sudo rm -rf "$TEMP_DIR"
    greenprint "    Stop httpd service"
    sudo systemctl disable httpd --now
}

#Main work flow to run this script
function run_test {
    create_blueprint "install"
    compose_image "install"
    download_image "install"
    install_image
    check_vm_status "install"
    create_blueprint "upgrade"
    compose_image "upgrade"
    download_image "upgrade"
    upgrade_image
    check_vm_status "upgrade"
    run_ansbile_playbook
}

#==========================================================================
# Test edge image type rhel-edge-commit
#==========================================================================
greenprint "*** Test started for RHEL 8.4 Edge Type rhel-edge-commit ***"
# Prepare the test environment
before_test
# Test edge image type rhel-edge-commit
run_test
# Cleanup the environment
after_test
greenprint "*** Test ended ***"
exit 0




