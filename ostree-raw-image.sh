#!/bin/bash
set -euox pipefail

# Provision the software under test.
./setup.sh

# Get OS data.
source /etc/os-release
ARCH=$(uname -m)

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="ostree-raw-${TEST_UUID}"
DOCKERHUB_REPO_URL="docker://registry.hub.docker.com/${DOCKERHUB_USERNAME}/rhel-edge"
DOCKERHUB_REPO_TAG=$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')
BIOS_GUEST_ADDRESS=192.168.100.50
UEFI_GUEST_ADDRESS=192.168.100.51
PROD_REPO_URL=http://192.168.100.1/repo
PROD_REPO=/var/www/html/repo
STAGE_REPO_ADDRESS=192.168.200.1
STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"
REF_PREFIX="rhel-edge"
CONTAINER_TYPE=edge-container
CONTAINER_FILENAME=container.tar
RAW_TYPE=edge-raw-image
RAW_FILENAME=image.raw.xz
# Workaround BZ#2108646
BOOT_ARGS="uefi"
# RHEL and CS default ostree os_name is redhat
# But Fedora uses fedora-iot
ANSIBLE_OS_NAME="redhat"

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)
EDGE_USER_PASSWORD=foobar
# Mount /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
# It's RHEL 9.2 and above, CS9, Fedora 37 and above ONLY
SYSROOT_RO="false"

# Prepare osbuild-composer repository file
sudo mkdir -p /etc/osbuild-composer/repositories

# RHEL 8.8 and CS8 is still RO for /sysroot on raw image and simplified installer
# The RO setting on RHEL 8.8 and CS8 is not configured by ostree, but osbuild-composer
# by PR https://github.com/osbuild/osbuild-composer/pull/3178
case "${ID}-${VERSION_ID}" in
    "rhel-8.8")
        OSTREE_REF="rhel/8/${ARCH}/edge"
        PARENT_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        ADD_SSSD="true"
        USER_IN_RAW="true"
        SYSROOT_RO="false"
        ;;
    "rhel-8.10")
        OSTREE_REF="rhel/8/${ARCH}/edge"
        PARENT_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        ADD_SSSD="true"
        USER_IN_RAW="true"
        SYSROOT_RO="false"
        ;;
    "rhel-9.3")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        PARENT_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9-unknown"
        ADD_SSSD="true"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ;;
    "rhel-9.4")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        PARENT_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9-unknown"
        ADD_SSSD="true"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ;;
    "rhel-9.5")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        PARENT_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9-unknown"
        ADD_SSSD="true"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ANSIBLE_OS_NAME="rhel-edge"
        ;;
    "centos-9")
        OSTREE_REF="centos/9/${ARCH}/edge"
        PARENT_REF="centos/9/${ARCH}/edge"
        OS_VARIANT="centos-stream9"
        ADD_SSSD="true"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ANSIBLE_OS_NAME="rhel-edge"
        ;;
    "fedora-39")
        CONTAINER_TYPE=fedora-iot-container
        RAW_TYPE=iot-raw-image
        OSTREE_REF="fedora/39/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        ADD_SSSD="false"
        ANSIBLE_OS_NAME="fedora-iot"
        USER_IN_RAW="true"
        REF_PREFIX="fedora-iot"
        SYSROOT_RO="true"
        ;;
    "fedora-40")
        CONTAINER_TYPE=fedora-iot-container
        RAW_TYPE=iot-raw-image
        OSTREE_REF="fedora/40/${ARCH}/iot"
        OS_VARIANT="fedora-rawhide"
        ADD_SSSD="false"
        ANSIBLE_OS_NAME="fedora-iot"
        USER_IN_RAW="true"
        REF_PREFIX="fedora-iot"
        SYSROOT_RO="true"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Compare rpm package version
function nvrGreaterOrEqual {
    local rpm_name=$1
    local min_version=$2

    set +e

    rpm_version=$(rpm -q --qf "%{version}" "${rpm_name}")
    rpmdev-vercmp "${rpm_version}" "${min_version}" 1>&2
    if [ "$?" != "12" ]; then
        # 0 - rpm_version == min_version
        # 11 - rpm_version > min_version
        # 12 - rpm_version < min_version
        set -e
        return
    fi

    set -e
    false
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-raw-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-raw-${COMPOSE_ID}.json

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
    elif [ $# -eq 4 ]; then
        repo_url=$3
        parent_ref=$4
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" --parent "$parent_ref" --url "$repo_url" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    else
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    fi

    if nvrGreaterOrEqual "weldr-client" "35.6"; then
        COMPOSE_ID=$(jq -r '.[0].body.build_id' "$COMPOSE_START")
    else
        COMPOSE_ID=$(jq -r '.body.build_id' "$COMPOSE_START")
    fi

    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null

        if nvrGreaterOrEqual "weldr-client" "35.6"; then
            COMPOSE_STATUS=$(jq -r '.[0].body.queue_status' "$COMPOSE_INFO")
        else
            COMPOSE_STATUS=$(jq -r '.body.queue_status' "$COMPOSE_INFO")
        fi

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

    # Clear vm
    if [[ $(sudo virsh domstate "${IMAGE_KEY}-uefi") == "running" ]]; then
        sudo virsh destroy "${IMAGE_KEY}-uefi"
    fi
    sudo virsh undefine "${IMAGE_KEY}-uefi" --nvram
    # Remove qcow2 file.
    sudo virsh vol-delete --pool images "${IMAGE_KEY}-uefi.qcow2"

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
# Have a clean prod repo
greenprint "🔧 Prepare edge prod repo"
sudo rm -rf "$PROD_REPO"
sudo mkdir -p "$PROD_REPO"
sudo ostree --repo="$PROD_REPO" init --mode=archive
sudo ostree --repo="$PROD_REPO" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"

# Prepare stage repo network
greenprint "🔧 Prepare stage repo network"
sudo podman network inspect edge >/dev/null 2>&1 || sudo podman network create --driver=bridge --subnet=192.168.200.0/24 --gateway=192.168.200.254 edge

##########################################################
##
## Build edge-container image and start it in podman
##
##########################################################

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
EOF

# Fedora does not have kernel-rt
if [[ "$ID" != "fedora" ]]; then
    tee -a "$BLUEPRINT_FILE" >> /dev/null << EOF
[customizations.kernel]
name = "kernel-rt"
EOF
fi

# For BZ#2088459, RHEL 8.6 and 9.0 will not have new release which fix this issue
# RHEL 8.6 and 9.0 will not include sssd package in blueprint
if [[ "${ADD_SSSD}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[packages]]
name = "sssd"
version = "*"
EOF
fi

# User in raw image blueprint is not for RHEL 9.1, 8.7 and before
if [[ "$USER_IN_RAW" == "false" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "${SSH_KEY_PUB}"
home = "/home/admin/"
groups = ["wheel"]
EOF
fi

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

# Clear stage repo running env
greenprint "🧹 Clearing stage repo running env"
# Remove any status containers if exist
sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
# Remove all images
sudo podman rmi -f -a

# Deal with rhel-edge container
greenprint "Uploading image to docker hub"
IMAGE_FILENAME="${COMPOSE_ID}-${CONTAINER_FILENAME}"
sudo skopeo copy --dest-creds "${DOCKERHUB_USERNAME}:${DOCKERHUB_PASSWORD}" "oci-archive:${IMAGE_FILENAME}" "${DOCKERHUB_REPO_URL}:${DOCKERHUB_REPO_TAG}"
# Clear image file
sudo rm -f "$IMAGE_FILENAME"

# Run edge stage repo
greenprint "🛰 Running edge stage repo"
sudo podman pull --creds "${DOCKERHUB_USERNAME}:${DOCKERHUB_PASSWORD}" "${DOCKERHUB_REPO_URL}:${DOCKERHUB_REPO_TAG}"
sudo podman run -d --name rhel-edge --network edge --ip "$STAGE_REPO_ADDRESS" "${DOCKERHUB_REPO_URL}:${DOCKERHUB_REPO_TAG}"
# Clear image file
sudo rm -f "$IMAGE_FILENAME"

# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' rhel-edge)" == "true" ]; do
    sleep 1;
done;

# Sync raw image edge content
greenprint "📡 Sync raw image content from stage repo"
sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage "$OSTREE_REF"

# Clean compose and blueprints.
greenprint "🧽 Clean up container blueprint and compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete container > /dev/null

# Remove tag from dockerhub
greenprint "Remove tag from docker hub repo"
HUB_TOKEN=$(curl -s -H "Content-Type: application/json" -X POST -d "{\"username\": \"$DOCKERHUB_USERNAME\", \"password\": \"$DOCKERHUB_PASSWORD\"}" https://hub.docker.com/v2/users/login/ | jq -r .token)
curl -i -X DELETE \
  -H "Accept: application/json" \
  -H "Authorization: JWT $HUB_TOKEN" \
  "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/rhel-edge/tags/${DOCKERHUB_REPO_TAG}/"

############################################################
##
## Build edge-raw-image
##
############################################################

# Write a blueprint for raw image image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "raw"
description = "A rhel-edge raw image"
version = "0.0.1"
modules = []
groups = []
EOF

# User in raw image blueprint is not for RHEL 9.1, 8.7 and before
if [[ "$USER_IN_RAW" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "${SSH_KEY_PUB}"
home = "/home/admin/"
groups = ["wheel"]
EOF
fi

greenprint "📄 raw image blueprint"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing raw image blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve raw

# Build raw image.
# Test --url arg following by URL with tailling slash for bz#1942029
build_image raw "${RAW_TYPE}" "${PROD_REPO_URL}/"

# Download the image
greenprint "📥 Downloading the raw image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
RAW_FILENAME="${COMPOSE_ID}-${RAW_FILENAME}"

greenprint "Extracting and converting the raw image to a qcow2 file"
sudo xz -d "${RAW_FILENAME}"
sudo qemu-img convert -f raw "${COMPOSE_ID}-image.raw" -O qcow2 "${IMAGE_KEY}.qcow2"
# Remove raw file
sudo rm -f "${COMPOSE_ID}-image.raw"

# Clean compose and blueprints.
greenprint "🧹 Clean up raw blueprint and compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete raw > /dev/null

# Prepare qcow2 file for tests
# Fedora raw image does not support BIOS
# https://github.com/osbuild/osbuild-composer/pull/3038/commits/fa1417e4ba031af343314ff6959a974ace117b19
if [[ "$ID" != "fedora" ]]; then
    sudo cp "${IMAGE_KEY}.qcow2" /var/lib/libvirt/images/"${IMAGE_KEY}-bios.qcow2"
    LIBVIRT_IMAGE_PATH_BIOS=/var/lib/libvirt/images/"${IMAGE_KEY}-bios.qcow2"
fi
sudo cp "${IMAGE_KEY}.qcow2" /var/lib/libvirt/images/"${IMAGE_KEY}-uefi.qcow2"
LIBVIRT_IMAGE_PATH_UEFI=/var/lib/libvirt/images/"${IMAGE_KEY}-uefi.qcow2"

# Ensure SELinux is happy with our new images.
greenprint "👿 Running restorecon on image directory"
sudo restorecon -Rv /var/lib/libvirt/images/

# Remove qcow2 file
sudo rm -f "${IMAGE_KEY}.qcow2"

# Fedora raw image does not support BIOS
# https://github.com/osbuild/osbuild-composer/pull/3038/commits/fa1417e4ba031af343314ff6959a974ace117b19
if [[ "$ID" != "fedora" ]]; then
    ##################################################################
    ##
    ## Install and test edge vm with edge-raw-image (BIOS)
    ##
    ##################################################################
    greenprint "💿 Installing raw image on BIOS VM"
    sudo virt-install  --name="${IMAGE_KEY}-bios"\
                    --disk path="${LIBVIRT_IMAGE_PATH_BIOS}",format=qcow2 \
                    --ram 3072 \
                    --vcpus 2 \
                    --network network=integration,mac=34:49:22:B0:83:30 \
                    --import \
                    --os-type linux \
                    --os-variant ${OS_VARIANT} \
                    --nographics \
                    --noautoconsole \
                    --wait=-1 \
                    --noreboot

    # Start VM.
    greenprint "💻 Start BIOS VM"
    sudo virsh start "${IMAGE_KEY}-bios"

    # Check for ssh ready to go.
    greenprint "🛃 Checking for SSH is ready to go"
    for _ in $(seq 0 30); do
        RESULTS="$(wait_for_ssh_up $BIOS_GUEST_ADDRESS)"
        if [[ $RESULTS == 1 ]]; then
            echo "SSH is ready now! 🥳"
            break
        fi
        sleep 10
    done

    # Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${BIOS_GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'
    # Sleep 10 seconds here to make sure vm restarted already
    sleep 10
    for _ in $(seq 0 30); do
        RESULTS="$(wait_for_ssh_up $BIOS_GUEST_ADDRESS)"
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

    # Add instance IP address into /etc/ansible/hosts
    tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${BIOS_GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes 
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

    # Test IoT/Edge OS
    podman run --network=host --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${INSTALL_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" check-ostree.yaml || RESULTS=0
    check_result

    ##################################################################
    ##
    ## Build rebased ostree repo
    ##
    ##################################################################

    # Write a blueprint for ostree image.
    # NB: no ssh key in the upgrade commit because there is no home dir
    tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "rebase"
description = "An rebase rhel-edge container image"
version = "0.0.2"
modules = []
groups = []

[[packages]]
name = "python3"
version = "*"

[[packages]]
name = "wget"
version = "*"

[customizations.kernel]
name = "kernel-rt"

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
home = "/home/admin/"
groups = ["wheel"]
EOF

    # For BZ#2088459, RHEL 8.6 and 9.0 will not have new release which fix this issue
    # RHEL 8.6 and 9.0 will not include sssd package in blueprint
    if [[ "${ADD_SSSD}" == "true" ]]; then
        tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[packages]]
name = "sssd"
version = "*"
EOF
    fi

    greenprint "📄 rebase blueprint"
    cat "$BLUEPRINT_FILE"

    # Prepare the blueprint for the compose.
    greenprint "📋 Preparing rebase blueprint"
    sudo composer-cli blueprints push "$BLUEPRINT_FILE"
    sudo composer-cli blueprints depsolve rebase

    # Build upgrade image.
    OSTREE_REF="test/redhat/x/${ARCH}/edge"
    build_image rebase  "${CONTAINER_TYPE}" "$PROD_REPO_URL" "$PARENT_REF"

    # Download the image
    greenprint "📥 Downloading the rebase image"
    sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null

    # Clear stage repo running env
    greenprint "🧹 Clearing stage repo running env"
    # Remove any status containers if exist
    sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
    # Remove all images
    sudo podman rmi -f -a

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
    greenprint "⛓ Pull rebase to prod mirror"
    sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage "$OSTREE_REF"

    # Get ostree commit value.
    greenprint "🕹 Get ostree rebase commit value"
    REBASE_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

    # Clean compose and blueprints.
    greenprint "🧽 Clean up rebase blueprint and compose"
    sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
    sudo composer-cli blueprints delete rebase > /dev/null

    # Rebase to new REF.
    greenprint "🗳 Rebase to new ostree REF"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${BIOS_GUEST_ADDRESS} "echo ${EDGE_USER_PASSWORD} |sudo -S rpm-ostree rebase ${REF_PREFIX}:${OSTREE_REF}"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${BIOS_GUEST_ADDRESS} "echo ${EDGE_USER_PASSWORD} |nohup sudo -S systemctl reboot &>/dev/null & exit"

    # Sleep 10 seconds here to make sure vm restarted already
    sleep 10

    for _ in $(seq 0 30); do
        RESULTS="$(wait_for_ssh_up $BIOS_GUEST_ADDRESS)"
        if [[ $RESULTS == 1 ]]; then
            echo "SSH is ready now! 🥳"
            break
        fi
        sleep 10
    done

    check_result

    # Add instance IP address into /etc/ansible/hosts
    tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${BIOS_GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

    # Test IoT/Edge OS
    podman run --network=host --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${REBASE_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" check-ostree.yaml || RESULTS=0

    check_result

    # Clean up BIOS VM
    greenprint "🧹 Clean up BIOS VM"
    if [[ $(sudo virsh domstate "${IMAGE_KEY}-bios") == "running" ]]; then
        sudo virsh destroy "${IMAGE_KEY}-bios"
    fi
    sudo virsh undefine "${IMAGE_KEY}-bios"
    sudo virsh vol-delete --pool images "${IMAGE_KEY}-bios.qcow2"
else
    greenprint "Skipping BIOS boot for Fedora IoT (not supported)"
fi

# Re configure OSTREE_REF because it's change to "test/redhat/x/${ARCH}/edge" by above rebase test
if [[ "$ID" == fedora ]]; then
    OSTREE_REF="${ID}/${VERSION_ID}/${ARCH}/iot"
elif [[ "$VERSION_ID" == 8* ]]; then
    OSTREE_REF="${ID}/8/${ARCH}/edge"
else
    OSTREE_REF="${ID}/9/${ARCH}/edge"
fi

##################################################################
##
## Install and test edge vm with edge-raw-image (UEFI)
##
##################################################################
greenprint "💿 Installing raw image on UEFI VM"
sudo virt-install  --name="${IMAGE_KEY}-uefi"\
                   --disk path="${LIBVIRT_IMAGE_PATH_UEFI}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:31 \
                   --os-type linux \
                   --os-variant ${OS_VARIANT} \
                   --boot ${BOOT_ARGS} \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --import \
                   --noreboot

# Start VM.
greenprint "💻 Start UEFI VM"
sudo virsh start "${IMAGE_KEY}-uefi"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $UEFI_GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${UEFI_GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $UEFI_GUEST_ADDRESS)"
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

# Add instance IP address into /etc/ansible/hosts
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${UEFI_GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes 
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
podman run --network=host --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${INSTALL_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" check-ostree.yaml || RESULTS=0
check_result

##################################################################
##
## Upgrade and test edge vm with edge-raw-image (UEFI)
##
##################################################################

# Write a blueprint for ostree image.
# NB: no ssh key in the upgrade commit because there is no home dir
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
name = "wget"
version = "*"

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
home = "/home/admin/"
groups = ["wheel"]
EOF

# Fedora does not have kernel-rt
if [[ "$ID" != "fedora" ]]; then
    tee -a "$BLUEPRINT_FILE" >> /dev/null << EOF
[customizations.kernel]
name = "kernel-rt"
EOF
fi

# For BZ#2088459, RHEL 8.6 and 9.0 will not have new release which fix this issue
# RHEL 8.6 and 9.0 will not include sssd package in blueprint
if [[ "${ADD_SSSD}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[packages]]
name = "sssd"
version = "*"
EOF
fi

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

# Clear stage repo running env
greenprint "🧹 Clearing stage repo running env"
# Remove any status containers if exist
sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
# Remove all images
sudo podman rmi -f -a

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

if [[ "$ID" == "fedora" ]]; then
    # The Fedora IoT Raw image sets the fedora-iot remote URL to https://ostree.fedoraproject.org/iot
    # Replacing with our own local repo
    greenprint "Replacing default remote"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${UEFI_GUEST_ADDRESS} "echo ${EDGE_USER_PASSWORD} |sudo -S ostree remote delete ${ANSIBLE_OS_NAME}"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${UEFI_GUEST_ADDRESS} "echo ${EDGE_USER_PASSWORD} |sudo -S ostree remote add --no-gpg-verify ${ANSIBLE_OS_NAME} ${PROD_REPO_URL}"
fi

# Upgrade image/commit.
greenprint "🗳 Upgrade ostree image/commit"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${UEFI_GUEST_ADDRESS} "echo ${EDGE_USER_PASSWORD} |sudo -S rpm-ostree upgrade"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@${UEFI_GUEST_ADDRESS} "echo ${EDGE_USER_PASSWORD} |nohup sudo -S systemctl reboot &>/dev/null & exit"

# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $UEFI_GUEST_ADDRESS)"
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
${UEFI_GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes 
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
podman run --network=host --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${UPGRADE_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" check-ostree.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0
