#!/bin/bash

set -euo pipefail

# Provision the software under test.
./setup.sh

# Get OS data.
source /etc/os-release
ARCH=$(uname -m)

# Install govc
GOVC_VERSION="v0.30.5"
sudo curl -L -o - "https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/govc_Linux_x86_64.tar.gz" | sudo tar -C /usr/local/bin -xvzf - govc

# Allow http service in firewall to enable ignition
sudo firewall-cmd --permanent --zone=public --add-service=http
sudo firewall-cmd --reload

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="edge-${TEST_UUID}"
HOST_IP_ADDRESS=$(ip addr show "$(ip route | awk '/default/ { print $5 }')" | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)
PROD_REPO_URL=http://${HOST_IP_ADDRESS}/repo
PROD_REPO=/var/www/html/repo
STAGE_REPO_ADDRESS=192.168.200.1
STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"
ARTIFACTS="${ARTIFACTS:-/tmp/artifacts}"
CONTAINER_TYPE=edge-container
CONTAINER_FILENAME=container.tar
VSPHERE_IMAGE_TYPE=edge-vsphere
VSPHERE_FILENAME=image.vmdk
REF_PREFIX="rhel-edge"
OS_NAME="redhat"

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)

# Ignition setup
IGNITION_SERVER_FOLDER=/var/www/html/ignition
IGNITION_SERVER_URL=http://${HOST_IP_ADDRESS}/ignition
IGNITION_USER=core
IGNITION_USER_PASSWORD=foobar

SYSROOT_RO="true"

DATACENTER_70="Datacenter7.0"
DATASTORE_70="datastore-80"
DATACENTER_70_POOL="/Datacenter7.0/host/Edge/Resources"
# DATACENTER_67="Datacenter6.7"
# DATASTORE_67="datastore-225"
# DATACENTER_67_POOL="/Datacenter6.7/host/Cluster6.7/Resources"

# Workdaround for creating rhel9 and centos9 on dc67, change guest_id to 8
case "${ID}-${VERSION_ID}" in
    "rhel-9.4" )
        OSTREE_REF="rhel/9/${ARCH}/edge"
        # GUEST_ID_DC67="rhel8_64Guest"
        GUEST_ID_DC70="rhel9_64Guest"
        ;;
    "rhel-9.5" )
        OSTREE_REF="rhel/9/${ARCH}/edge"
        # GUEST_ID_DC67="rhel8_64Guest"
        GUEST_ID_DC70="rhel9_64Guest"
        OS_NAME="rhel-edge"
        ;;
    "rhel-9.6" )
        OSTREE_REF="rhel/9/${ARCH}/edge"
        # GUEST_ID_DC67="rhel8_64Guest"
        GUEST_ID_DC70="rhel9_64Guest"
        OS_NAME="rhel-edge"
        ;;
    "centos-9")
        OSTREE_REF="centos/9/${ARCH}/edge"
        # GUEST_ID_DC67="centos8_64Guest"
        GUEST_ID_DC70="centos9_64Guest"
        OS_NAME="rhel-edge"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

if [[ "${ID}-${VERSION_ID}" == "rhel-9.5" ]]; then
   OS_NAME="rhel-edge"
fi

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-installer-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-installer-${COMPOSE_ID}.json

    # Download the metadata.
    sudo composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    sudo tar -xf "$TARBALL" -C "${TEMPDIR}"
    sudo rm -f "$TARBALL"

    # Move the JSON file into place.
    sudo cat "${TEMPDIR}"/"${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
}

# Build ostree image.
build_image() {
    blueprint_name=$1
    image_type=$2

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!
    # Stop watching the worker journal when exiting.
    trap 'sudo pkill -P ${WORKER_JOURNAL_PID}' EXIT

    # Start the compose.
    greenprint "🚀 Starting compose"
    if [ $# -eq 3 ]; then
        repo_url=$3
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" --url "$repo_url" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    else
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    fi

    COMPOSE_ID=$(jq -r '.[0].body.build_id' "$COMPOSE_START")


    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null

        COMPOSE_STATUS=$(jq -r '.[0].body.queue_status' "$COMPOSE_INFO")

        # Is the compose finished?
        if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
            break
        fi

        # Wait 30 seconds and try again.
        sleep 5
    done

    # Capture the compose logs from osbuild.
    greenprint "💬 Getting compose log and metadata"
    get_compose_log "$COMPOSE_ID"
    get_compose_metadata "$COMPOSE_ID"

    # Kill the journal monitor immediately and remove the trap
    sudo pkill -P ${WORKER_JOURNAL_PID}
    trap - EXIT

    # Did the compose finish with success?
    if [[ $COMPOSE_STATUS != FINISHED ]]; then
        echo "Something went wrong with the compose. 😢"
        exit 1
    fi
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@"${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"

    # Remove any status containers if exist
    sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
    # Remove all images
    sudo podman rmi -f -a

    # Remove prod repo
    sudo rm -rf "$PROD_REPO"

    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"

    # Stop prod repo http service
    sudo systemctl disable --now httpd

    # Remove vm
    # govc vm.destroy -dc="Datacenter6.7" "${DC67_VSPHERE_VM_NAME}"
    govc vm.destroy -dc="${DATACENTER_70}" "${DC70_VSPHERE_VM_NAME}"
}

# Test result checking
check_result () {
    greenprint "🎏 Checking for test result"
    if [[ $RESULTS == 1 ]]; then
        greenprint "💚 Success"
    else
        greenprint "❌ Failed"
        clean_up
        exit 1
    fi
}

###########################################################
##
## Prepare edge prod and stage repo
##
###########################################################
greenprint "🔧 Prepare edge prod repo"

# Have a clean prod repo
sudo rm -rf "$PROD_REPO"
sudo mkdir -p "$PROD_REPO"
sudo ostree --repo="$PROD_REPO" init --mode=archive
sudo ostree --repo="$PROD_REPO" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"

# Clear container running env
greenprint "🧹 Clearing container running env"
# Remove any status containers if exist
sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
# Remove all images
sudo podman rmi -f -a

# Prepare stage repo network, also needed for FDO AIO to correctly resolve ips
greenprint "🔧 Prepare stage repo network"
sudo podman network inspect edge >/dev/null 2>&1 || sudo podman network create --driver=bridge --subnet=192.168.200.0/24 --gateway=192.168.200.254 edge

##############################################################
##
## Build edge-container image
##
##############################################################
# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "container"
description = "A base rhel-edge container image"
version = "0.0.1"
modules = []
groups = []

[[packages]]
name = "python3"
version = "*"

[[packages]]
name = "open-vm-tools"
version = "*"
EOF

greenprint "📄 container blueprint"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing container blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve container

# Build container image.
build_image container "${CONTAINER_TYPE}"

# Download the image
greenprint "📥 Downloading the container image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null

# Deal with stage repo image
greenprint "🗜 Starting container"
IMAGE_FILENAME="${COMPOSE_ID}-${CONTAINER_FILENAME}"
sudo podman pull "oci-archive:${IMAGE_FILENAME}"
sudo podman images
# Run edge stage repo
greenprint "🛰 Running edge stage repo"
# Get image id to run image
EDGE_IMAGE_ID=$(sudo podman images --filter "dangling=true" --format "{{.ID}}")
sudo podman run -d --name rhel-edge --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Clear image file
sudo rm -f "$IMAGE_FILENAME"

# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' rhel-edge)" == "true" ]; do
    sleep 1;
done;

# Sync installer edge content
greenprint "📡 Sync installer content from stage repo"
sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage "$OSTREE_REF"

# Clean compose and blueprints.
greenprint "🧽 Clean up container blueprint and compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete container > /dev/null

##################################################################
##
## Generate ignition configuration
##
##################################################################
greenprint "📋 Preparing ignition environment"
sudo mkdir -p "$IGNITION_SERVER_FOLDER"
IGNITION_CONFIG_PATH="${IGNITION_SERVER_FOLDER}/config.ign"
sudo tee "$IGNITION_CONFIG_PATH" > /dev/null << EOF
{
  "ignition": {
    "config": {
      "merge": [
        {
          "source": "${IGNITION_SERVER_URL}/sample.ign"
        }
      ]
    },
    "timeouts": {
      "httpTotal": 30
    },
    "version": "3.3.0"
  },
  "passwd": {
    "users": [
      {
        "groups": [
          "wheel"
        ],
        "name": "$IGNITION_USER",
        "passwordHash": "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl.",
        "sshAuthorizedKeys": [
          "$SSH_KEY_PUB"
        ]
      }
    ]
  }
}
EOF

IGNITION_CONFIG_SAMPLE_PATH="${IGNITION_SERVER_FOLDER}/sample.ign"
sudo tee "$IGNITION_CONFIG_SAMPLE_PATH" > /dev/null << EOF
{
  "ignition": {
    "version": "3.3.0"
  },
  "storage": {
    "files": [
      {
        "path": "/usr/local/bin/startup.sh",
        "contents": {
          "compression": "",
          "source": "data:;base64,IyEvYmluL2Jhc2gKZWNobyAiSGVsbG8sIFdvcmxkISIK"
        },
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "[Unit]\nDescription=A hello world unit!\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/local/bin/startup.sh\n[Install]\nWantedBy=multi-user.target\n",
        "enabled": true,
        "name": "hello.service"
      },
      {
        "dropins": [
          {
            "contents": "[Service]\nEnvironment=LOG_LEVEL=trace\n",
            "name": "log_trace.conf"
          }
        ],
        "name": "fdo-client-linuxapp.service"
      }
    ]
  }
}
EOF

##################################################################
##
## Build edge-vsphere with Ignition firstboot
##
##################################################################
greenprint "📋 Build edge-vsphere image"
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "vmdk"
description = "A rhel-edge vmdk image"
version = "0.0.1"
modules = []
groups = []

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "${SSH_KEY_PUB}"
home = "/home/admin/"
groups = ["wheel"]

[customizations.ignition.firstboot]
url = "${IGNITION_SERVER_URL}/config.ign"
EOF

greenprint "📄 vmdk blueprint"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing installer blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve vmdk

# Build simplified installer iso image.
build_image vmdk "${VSPHERE_IMAGE_TYPE}" "${PROD_REPO_URL}/"

# Download the image
greenprint "📥 Downloading the vmdk image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
VMDK_FILENAME="${COMPOSE_ID}-${VSPHERE_FILENAME}"
sudo chmod 644 "${VMDK_FILENAME}"
sudo chown "$(whoami)" "${VMDK_FILENAME}"

# Clean compose and blueprints.
greenprint "🧹 Clean up vmdk blueprint and compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete vmdk > /dev/null

##################################################################
##
## Upload image to datastore
##
##################################################################
greenprint "📋 Uploading vmdk image to vsphere datacenter 7.0"
govc import.vmdk -dc="${DATACENTER_70}" -ds="${DATASTORE_70}" -pool="${DATACENTER_70_POOL}" "${VMDK_FILENAME}" > /dev/null
# greenprint "📋 Copying vmdk image to vsphere datacenter 6.7"
# govc datastore.mkdir -dc="${DATACENTER_67}" -ds="${DATASTORE_67}" "${COMPOSE_ID}-image"
# govc datastore.cp -dc="${DATACENTER_70}" -ds="${DATASTORE_70}" -dc-target="${DATACENTER_67}" -ds-target="${DATASTORE_67}" "${COMPOSE_ID}-image/${VMDK_FILENAME}" "${COMPOSE_ID}-image/${VMDK_FILENAME}" > /dev/null

##################################################################
##
## Create vm on datacenter7.0-amd and test it
##
##################################################################
# Create vm with vmdk image
greenprint "📋 Create vm in vsphere datacenter 7.0"
DC70_VSPHERE_VM_NAME="${COMPOSE_ID}-70"
govc vm.create -dc="${DATACENTER_70}" -ds="${DATASTORE_70}" -pool="${DATACENTER_70_POOL}" \
    -net="VM Network" -net.adapter=vmxnet3 -disk.controller=pvscsi -on=false -c=2 -m=4096 \
    -g="${GUEST_ID_DC70}" -firmware=efi "${DC70_VSPHERE_VM_NAME}"
govc vm.disk.attach -dc="${DATACENTER_70}" -ds="${DATASTORE_70}" -vm "${DC70_VSPHERE_VM_NAME}" \
    -link=false -disk="${COMPOSE_ID}-image/${VMDK_FILENAME}"
govc vm.power -on -dc="${DATACENTER_70}" "${DC70_VSPHERE_VM_NAME}"
DC70_GUEST_ADDRESS=$(govc vm.ip -v4 -dc="${DATACENTER_70}" -wait=10m "${DC70_VSPHERE_VM_NAME}")
greenprint "🛃 Edge VM IP address is: ${DC70_GUEST_ADDRESS}"

# Run ansible check on edge vm
# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up "${DC70_GUEST_ADDRESS}")"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

greenprint "🕹 Get ostree install commit value"
INSTALL_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${DC70_GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes
ansible_become_method=sudo
ansible_become_pass=${IGNITION_USER_PASSWORD}
EOF

# Test IoT/Edge OS
podman run --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z \
    --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory \
    -e ignition="true" \
    -e os_name="${OS_NAME}" \
    -e ostree_commit="${INSTALL_HASH}" \
    -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" \
    -e fdo_credential="false" \
    -e sysroot_ro="$SYSROOT_RO" \
    check-ostree.yaml || RESULTS=0
check_result

##################################################################
##
## Create vm on datacenter6.7 and test it
##
##################################################################
# # Create vm with vmdk image
# greenprint "📋 Create vm in vsphere datacenter 6.7"
# DC67_VSPHERE_VM_NAME="${COMPOSE_ID}-67"
# govc vm.create -dc="${DATACENTER_67}" -ds="${DATASTORE_67}" -pool="${DATACENTER_67_POOL}" \
#     -net="VM Network" -net.adapter=vmxnet3 -disk.controller=pvscsi -on=false -c=2 -m=4096 \
#     -g="${GUEST_ID_DC67}" -firmware=efi "${DC67_VSPHERE_VM_NAME}"
# govc vm.disk.attach -dc="${DATACENTER_67}" -ds="${DATASTORE_67}" -vm "${DC67_VSPHERE_VM_NAME}" \
#     -link=false -disk="${COMPOSE_ID}-image/${VMDK_FILENAME}"
# govc vm.power -on -dc="${DATACENTER_67}" "${DC67_VSPHERE_VM_NAME}"
# DC67_GUEST_ADDRESS=$(govc vm.ip -v4 -dc="${DATACENTER_67}" -wait=10m "${DC67_VSPHERE_VM_NAME}")
# greenprint "🛃 Edge VM IP address is: ${DC67_GUEST_ADDRESS}"

# # Run ansible check on edge vm
# # Check for ssh ready to go.
# greenprint "🛃 Checking for SSH is ready to go"
# for _ in $(seq 0 30); do
#     RESULTS="$(wait_for_ssh_up "${DC67_GUEST_ADDRESS}")"
#     if [[ $RESULTS == 1 ]]; then
#         echo "SSH is ready now! 🥳"
#         break
#     fi
#     sleep 10
# done

# # Check image installation result
# check_result

# greenprint "🕹 Get ostree install commit value"
# INSTALL_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

# tee "${TEMPDIR}"/inventory > /dev/null << EOF
# [ostree_guest]
# ${DC67_GUEST_ADDRESS}

# [ostree_guest:vars]
# ansible_python_interpreter=/usr/bin/python3
# ansible_user=${IGNITION_USER}
# ansible_private_key_file=${SSH_KEY}
# ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
# ansible_become=yes
# ansible_become_method=sudo
# ansible_become_pass=${IGNITION_USER_PASSWORD}
# EOF

# # Test IoT/Edge OS
# podman run --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z \
#     --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory \
#     -e ignition="true" \
#     -e os_name=redhat \
#     -e ostree_commit="${INSTALL_HASH}" \
#     -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" \
#     -e fdo_credential="false" \
#     -e sysroot_ro="$SYSROOT_RO" \
#     check-ostree.yaml || RESULTS=0
# check_result

##################################################################
##
## Build upgrade edge-vsphere image
##
##################################################################
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "upgrade"
description = "An upgrade rhel-edge container image"
version = "0.0.2"
modules = []
groups = []

[[packages]]
name = "python3"
version = "*"

[[packages]]
name = "open-vm-tools"
version = "*"

[[packages]]
name = "wget"
version = "*"
EOF

greenprint "📄 upgrade blueprint"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing upgrade blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve upgrade

# Build upgrade image.
build_image upgrade  "${CONTAINER_TYPE}" "$PROD_REPO_URL"

# Download the image
greenprint "📥 Downloading the upgrade image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null

# Delete installation rhel-edge container and its image
greenprint "🧹 Delete installation rhel-edge container and its image"
# Remove rhel-edge container if exists
sudo podman ps -q --filter name=rhel-edge --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
# Remove container image if exists
sudo podman images --filter "dangling=true" --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rmi -f

# Deal with stage repo container
greenprint "🗜 Extracting image"
IMAGE_FILENAME="${COMPOSE_ID}-${CONTAINER_FILENAME}"
sudo podman pull "oci-archive:${IMAGE_FILENAME}"
sudo podman images
# Clear image file
sudo rm -f "$IMAGE_FILENAME"

# Run edge stage repo
greenprint "🛰 Running edge stage repo"
# Get image id to run image
EDGE_IMAGE_ID=$(sudo podman images --filter "dangling=true" --format "{{.ID}}")
sudo podman run -d --name rhel-edge --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' rhel-edge)" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod mirror
greenprint "⛓ Pull upgrade to prod mirror"
sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage "$OSTREE_REF"
sudo ostree --repo="$PROD_REPO" static-delta generate "$OSTREE_REF"
sudo ostree --repo="$PROD_REPO" summary -u

# Get ostree commit value.
greenprint "🕹 Get ostree upgrade commit value"
UPGRADE_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

# Clean compose and blueprints.
greenprint "🧽 Clean up upgrade blueprint and compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete upgrade > /dev/null

##################################################################
##
## Run upgrade test on datacenter7.0 amd
##
##################################################################
greenprint "🗳 Upgrade ostree image/commit"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${IGNITION_USER}@${DC70_GUEST_ADDRESS}" "echo ${IGNITION_USER_PASSWORD} |sudo -S rpm-ostree upgrade"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${IGNITION_USER}@${DC70_GUEST_ADDRESS}" "echo ${IGNITION_USER_PASSWORD} |nohup sudo -S systemctl reboot &>/dev/null & exit"

# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
# shellcheck disable=SC2034  # Unused variables left for readability
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up "${DC70_GUEST_ADDRESS}")"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check ostree upgrade result
check_result

# Add instance IP address into /etc/ansible/hosts
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${DC70_GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${IGNITION_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes
ansible_become_method=sudo
ansible_become_pass=${IGNITION_USER_PASSWORD}
EOF

# Test IoT/Edge OS
podman run --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z \
    --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory \
    -e ignition="true" \
    -e os_name="${OS_NAME}" \
    -e ostree_commit="${UPGRADE_HASH}" \
    -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" \
    -e fdo_credential="false" \
    -e sysroot_ro="$SYSROOT_RO" \
    check-ostree.yaml || RESULTS=0
check_result

##################################################################
##
## Run upgrade test on datacenter6.7 intel
##
##################################################################
# greenprint "🗳 Upgrade ostree image/commit"
# sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${IGNITION_USER}@${DC67_GUEST_ADDRESS}" "echo ${IGNITION_USER_PASSWORD} |sudo -S rpm-ostree upgrade"
# sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${IGNITION_USER}@${DC67_GUEST_ADDRESS}" "echo ${IGNITION_USER_PASSWORD} |nohup sudo -S systemctl reboot &>/dev/null & exit"

# # Sleep 10 seconds here to make sure vm restarted already
# sleep 10

# # Check for ssh ready to go.
# greenprint "🛃 Checking for SSH is ready to go"
# # shellcheck disable=SC2034  # Unused variables left for readability
# for _ in $(seq 0 30); do
#     RESULTS="$(wait_for_ssh_up "${DC67_GUEST_ADDRESS}")"
#     if [[ $RESULTS == 1 ]]; then
#         echo "SSH is ready now! 🥳"
#         break
#     fi
#     sleep 10
# done

# # Check ostree upgrade result
# check_result

# # Add instance IP address into /etc/ansible/hosts
# tee "${TEMPDIR}"/inventory > /dev/null << EOF
# [ostree_guest]
# ${DC67_GUEST_ADDRESS}

# [ostree_guest:vars]
# ansible_python_interpreter=/usr/bin/python3
# ansible_user=${IGNITION_USER}
# ansible_private_key_file=${SSH_KEY}
# ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
# ansible_become=yes
# ansible_become_method=sudo
# ansible_become_pass=${IGNITION_USER_PASSWORD}
# EOF

# # Test IoT/Edge OS
# podman run --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z \
#     --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory \
#     -e ignition="true" \
#     -e os_name=redhat \
#     -e ostree_commit="${UPGRADE_HASH}" \
#     -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" \
#     -e fdo_credential="false" \
#     -e sysroot_ro="$SYSROOT_RO" \
#     check-ostree.yaml || RESULTS=0
# check_result

# Final success clean up
clean_up

exit 0
