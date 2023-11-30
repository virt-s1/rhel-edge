#!/bin/bash
set -exuo pipefail

# Get TEST_OS from $1
TEST_OS=$1
if [ $# -eq 2 ]; then
    UPGRADE_OS=$2
else
    UPGRADE_OS=$1
fi

# Get OS data.
source /etc/os-release
ARCH=$(uname -m)

# SSH setup.
SSH_USER="admin"
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)
EDGE_USER_PASSWORD=foobar

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Wait for cloud-init finished.
wait_for_cloud_init () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${1}" 'test -f /var/lib/cloud/instance/boot-finished && echo -n READY')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Test result checking
check_result () {
    greenprint "Checking for test result"
    if [[ $RESULTS == 1 ]]; then
        greenprint "💚 Success"
    else
        greenprint "❌ Failed"
        clean_up
        exit 1
    fi
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"
    # Clear builder vm
    sudo virsh destroy "$BUILDER_VM_NAME"
    sudo virsh undefine "$BUILDER_VM_NAME" --nvram
    sudo virsh vol-delete --pool images "$GUEST_IMAGE_PATH"
    # Clear edge commit vm
    sudo virsh destroy "${EDGE_RAW_VM_NAME}"
    sudo virsh undefine "${EDGE_RAW_VM_NAME}" --nvram
    sudo virsh vol-delete --pool images "$EDGE_RAW_IMAGE_PATH"
    # Remove repo folder.
    sudo rm -rf "$RAW_HTTPD_PATH"
    # Remove any status containers if exist
    sudo podman rm -f -a
    # Remove all images
    sudo podman rmi -f -a
    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"
}

# Variables before case
BOOT_ARGS="uefi"
CONTAINER_IMAGE_TYPE=edge-container
RAW_IMAGE_TYPE=edge-raw-image
RAW_FILENAME=image.raw.xz

# Set up variables.
TEMPDIR=$(mktemp -d)
LIBVIRT_IMAGE_PATH="/var/lib/libvirt/images"
RAW_HTTPD_PATH="/var/www/html/${TEST_OS}-${UPGRADE_OS}-raw"
BUILDER_VM_NAME="${TEST_OS}-raw-builder"
GUEST_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/guest-image-${TEST_OS}-raw.qcow2"
EDGE_RAW_VM_NAME="${TEST_OS}-${UPGRADE_OS}-raw"
EDGE_RAW_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/${TEST_OS}-${UPGRADE_OS}-raw.qcow2"
BLUEPRINT_FILE="${TEMPDIR}/blueprint.toml"
DOCKERHUB_REPO_URL="docker://registry.hub.docker.com/${DOCKERHUB_USERNAME}/rhel-edge"
DOCKERHUB_REPO_TAG=$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')
PROD_REPO_ADDRESS=192.168.100.1
PROD_REPO_URL="http://${PROD_REPO_ADDRESS}/${TEST_OS}-${UPGRADE_OS}-raw"
STAGE_REPO_ADDRESS=192.168.200.1
STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"

# Prepare cloud-init data
CLOUD_INIT_DIR=$(mktemp -d)
cp tools/meta-data "$CLOUD_INIT_DIR"

# Set useful things according to different distros.
case "$TEST_OS" in
    "rhel-8-8")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-8-8-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.88 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel8-unknown"
        OSTREE_REF="rhel/8/${ARCH}/edge"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-8/nightly/RHEL-8/latest-RHEL-8.8.0/compose/BaseOS/${ARCH}/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-8.8-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        USER_IN_RAW="true"
        SYSROOT_RO="false"
        ;;
    "rhel-9-2")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-2-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.92 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel9-unknown"
        OSTREE_REF="rhel/9/${ARCH}/edge"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.2.0/compose/BaseOS/${ARCH}/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.2-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ;;
    "centos-stream-8")
        OS_VARIANT="centos-stream8"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="centos/8/${ARCH}/edge"
        GUEST_IMAGE_URL="https://cloud.centos.org/centos/8-stream/${ARCH}/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-8-.*.qcow2<" | tr -d '><' | tail -1)
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        USER_IN_RAW="true"
        SYSROOT_RO="false"
        ;;
    "centos-stream-9")
        OS_VARIANT="centos-stream9"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="centos/9/${ARCH}/edge"
        GUEST_IMAGE_URL="https://odcs.stream.centos.org/production/latest-CentOS-Stream/compose/BaseOS/${ARCH}/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-9-.*.qcow2<" | tr -d '><')
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ;;
    "fedora-38")
        OS_VARIANT="fedora-unknown"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="fedora/38/${ARCH}/iot"
        CONTAINER_IMAGE_TYPE=iot-container
        RAW_IMAGE_TYPE=iot-raw-image
        GUEST_IMAGE_URL="https://download-cc-rdu01.fedoraproject.org/pub/fedora/linux/development/38/Cloud/${ARCH}/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-38-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="fedora-iot"
        REF_PREFIX="fedora-iot"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ;;
    "fedora-39")
        OS_VARIANT="fedora-unknown"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="fedora/39/${ARCH}/iot"
        CONTAINER_IMAGE_TYPE=iot-container
        RAW_IMAGE_TYPE=iot-raw-image
        GUEST_IMAGE_URL="https://download-cc-rdu01.fedoraproject.org/pub/fedora/linux/development/rawhide/Cloud/${ARCH}/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-Rawhide-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="fedora-iot"
        REF_PREFIX="fedora-iot"
        USER_IN_RAW="true"
        SYSROOT_RO="true"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Prepare ostree prod repo and configure stage repo
greenprint "Prepare ostree prod repo and configure stage repo"
sudo rm -rf "$RAW_HTTPD_PATH"
sudo mkdir -p "$RAW_HTTPD_PATH"
sudo ostree --repo="$RAW_HTTPD_PATH" init --mode=archive
sudo ostree --repo="$RAW_HTTPD_PATH" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"

# Download guest image
sudo curl --no-progress-meter -o "${GUEST_IMAGE_PATH}" "${GUEST_IMAGE_URL}/${GUEST_IMAGE_NAME}"
# Extend to 15G for image building required
sudo qemu-img resize "${GUEST_IMAGE_PATH}" 15G

# Set up a cloud-init ISO.
greenprint "💿 Creating a cloud-init ISO"
CLOUD_INIT_PATH="${LIBVIRT_IMAGE_PATH}/seed-${TEST_OS}-raw.iso"
sudo rm -f "$CLOUD_INIT_PATH"
pushd "$CLOUD_INIT_DIR"
    sudo mkisofs -o "$CLOUD_INIT_PATH" -V cidata \
        -r -J user-data meta-data > /dev/null 2>&1
popd
rm -rf "$CLOUD_INIT_DIR"

# Ensure SELinux is happy with image.
greenprint "👿 Running restorecon on image directory"
sudo restorecon -Rv /var/lib/libvirt/images/

# Import builder VM
sudo virt-install --name="$BUILDER_VM_NAME" \
                  --disk path="$GUEST_IMAGE_PATH",format=qcow2 \
                  --disk path="$CLOUD_INIT_PATH",device=cdrom \
                  --memory 3072 \
                  --vcpus 2 \
                  --network network=integration \
                  --os-variant "$OS_VARIANT" \
                  --boot uefi \
                  --import \
                  --noautoconsole \
                  --wait=-1 \
                  --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "$BUILDER_VM_NAME"

# Wait until VM has IP addr from dhcp server
greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "$BUILDER_VM_NAME" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

# Get VM IP address
greenprint "Get VM IP address"
BUILDER_VM_IP=$(sudo virsh domifaddr "$BUILDER_VM_NAME" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$BUILDER_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Wait for cloud-init finished.
greenprint "🛃 Wait for cloud-init finished"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_cloud_init "$BUILDER_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "Cloud-init finished! 🥳"
        break
    fi
    sleep 10
done

##################################################
##
## build edge/iot-container image
##
##################################################

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
name = "sssd"
version = "*"
EOF

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

# Create inventory file
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[builder]
${BUILDER_VM_IP}
[builder:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Build edge/iot-container image.
sudo podman run --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:"${ARCH}" ansible-playbook -v -i /tmp/inventory -e image_type="$CONTAINER_IMAGE_TYPE" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-container.tar" "${TEMPDIR}/edge-container.tar"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.tar'

# Remove cloud-init ISO.
sudo rm -f "$CLOUD_INIT_PATH"

# Deal with rhel-edge container
greenprint "Uploading image to docker hub"
sudo skopeo copy --dest-creds "${DOCKERHUB_USERNAME}:${DOCKERHUB_PASSWORD}" "oci-archive:${TEMPDIR}/edge-container.tar" "${DOCKERHUB_REPO_URL}:${DOCKERHUB_REPO_TAG}"
# Clear image file
sudo rm -f "${TEMPDIR}/edge-container.tar"

# Run edge stage repo
greenprint "🛰 Running edge stage repo"
sudo podman pull --creds "${DOCKERHUB_USERNAME}:${DOCKERHUB_PASSWORD}" "${DOCKERHUB_REPO_URL}:${DOCKERHUB_REPO_TAG}"
sudo podman run -d --name "${TEST_OS}-raw" --network edge --ip "$STAGE_REPO_ADDRESS" "${DOCKERHUB_REPO_URL}:${DOCKERHUB_REPO_TAG}"

# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' "${TEST_OS}-raw")" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod repo
sudo ostree --repo="$RAW_HTTPD_PATH" pull --mirror edge-stage "$OSTREE_REF"

# Clean container env
sudo podman rm -f "${TEST_OS}-raw"
sudo podman rmi -f "$(echo "${DOCKERHUB_REPO_URL}:${DOCKERHUB_REPO_TAG}" | grep -oP '(registry.*)')"

# Remove tag from dockerhub
greenprint "Remove tag from docker hub repo"
HUB_TOKEN=$(curl -s -H "Content-Type: application/json" -X POST -d "{\"username\": \"$DOCKERHUB_USERNAME\", \"password\": \"$DOCKERHUB_PASSWORD\"}" https://hub.docker.com/v2/users/login/ | jq -r .token)
curl -i -X DELETE \
  -H "Accept: application/json" \
  -H "Authorization: JWT $HUB_TOKEN" \
  "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/rhel-edge/tags/${DOCKERHUB_REPO_TAG}/"

##################################################
##
## build edge/iot-raw image
##
##################################################
# Write a blueprint for installer image.
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

# Build edge/iot-raw image.
sudo podman run --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:"${ARCH}" ansible-playbook -v -i /tmp/inventory -e image_type="$RAW_IMAGE_TYPE" -e repo_url="$PROD_REPO_URL" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-${RAW_FILENAME}" "${TEMPDIR}/${RAW_FILENAME}"

# If TEST OS is different from UPGRADE OS, destroy the old builder VM and create a new one
if [ $# -eq 2 ] && [ "$1" != "$2" ]; then
    # Clear builder vm
    sudo virsh destroy "$BUILDER_VM_NAME"
    sudo virsh undefine "$BUILDER_VM_NAME" --nvram
    sudo virsh vol-delete --pool images "$GUEST_IMAGE_PATH"
else
    # Keep builder VM and remove image in builder VM
    ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.xz'
fi

greenprint "Extracting and converting the raw image to a qcow2 file"
sudo xz -d "${TEMPDIR}/${RAW_FILENAME}"
sudo qemu-img convert -f raw "${TEMPDIR}/image.raw" -O qcow2 "$EDGE_RAW_IMAGE_PATH"
# Remove raw file
sudo rm -f "${TEMPDIR}/image.raw"

# UEFI installation test
# Install via raw image on UEFI vm
greenprint "💿 Install via raw image on UEFI vm"
sudo virt-install  --name="${EDGE_RAW_VM_NAME}" \
                   --disk path="${EDGE_RAW_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration \
                   --import \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --boot ${BOOT_ARGS} \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${EDGE_RAW_VM_NAME}"

# Wait until VM has IP addr from dhcp server
greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "${EDGE_RAW_VM_NAME}" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

# Get VM IP address
greenprint "Get VM IP address"
EDGE_RAW_VM_IP=$(sudo virsh domifaddr "${EDGE_RAW_VM_NAME}" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_RAW_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

# Get ostree commit value.
greenprint "🕹 Get ostree commit value"
OSTREE_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

# Add instance IP address into /etc/ansible/hosts
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${EDGE_RAW_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
sudo podman run --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:"${ARCH}" ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${OSTREE_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" check-ostree.yaml || RESULTS=0
check_result

#####################################################################
##
## Create a new builder VM if UPGRADE OS is different from TEST OS
##
#####################################################################
if [ $# -eq 2 ] && [ "$1" != "$2" ]; then
    # Prepare cloud-init data
    CLOUD_INIT_DIR=$(mktemp -d)
    cp tools/meta-data "$CLOUD_INIT_DIR"

    case "$UPGRADE_OS" in
        "rhel-8-8")
            sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-8-8-0.json
            sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.88 | sudo tee "${CLOUD_INIT_DIR}/user-data"
            OS_VARIANT="rhel8-unknown"
            UPGRADE_OSTREE_REF="rhel/8/${ARCH}/edge"
            GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-8/nightly/RHEL-8/latest-RHEL-8.8.0/compose/BaseOS/${ARCH}/images"
            GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-8.8-.*.qcow2<" | tr -d '><')
            SYSROOT_RO="false"
            ;;
        "rhel-9-2")
            sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-2-0.json
            sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.92 | sudo tee "${CLOUD_INIT_DIR}/user-data"
            OS_VARIANT="rhel9-unknown"
            UPGRADE_OSTREE_REF="rhel/9/${ARCH}/edge"
            GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.2.0/compose/BaseOS/${ARCH}/images"
            GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.2-.*.qcow2<" | tr -d '><')
            SYSROOT_RO="true"
            ;;
        "centos-stream-9")
            OS_VARIANT="centos-stream9"
            cp tools/user-data "$CLOUD_INIT_DIR"
            UPGRADE_OSTREE_REF="centos/9/${ARCH}/edge"
            GUEST_IMAGE_URL="https://odcs.stream.centos.org/production/latest-CentOS-Stream/compose/BaseOS/${ARCH}/images"
            GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-9-.*.qcow2<" | tr -d '><')
            BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
            SYSROOT_RO="true"
            ;;
        "fedora-38")
            OS_VARIANT="fedora-unknown"
            cp tools/user-data "$CLOUD_INIT_DIR"
            UPGRADE_OSTREE_REF="fedora/38/${ARCH}/iot"
            CONTAINER_IMAGE_TYPE=iot-container
            RAW_IMAGE_TYPE=iot-raw-image
            GUEST_IMAGE_URL="https://download-cc-rdu01.fedoraproject.org/pub/fedora/linux/development/38/Cloud/${ARCH}/images"
            GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-Rawhide-.*.qcow2<" | tr -d '><')
            SYSROOT_RO="true"
            ;;
        *)
            echo "unsupported distro: ${ID}-${VERSION_ID}"
            exit 1;;
    esac

    BUILDER_VM_NAME="${UPGRADE_OS}-raw-builder"
    GUEST_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/guest-image-${UPGRADE_OS}-raw.qcow2"

    # Download guest image
    sudo curl --no-progress-meter -o "${GUEST_IMAGE_PATH}" "${GUEST_IMAGE_URL}/${GUEST_IMAGE_NAME}"
    # Extend to 15G for image building required
    sudo qemu-img resize "${GUEST_IMAGE_PATH}" 15G

    # Set up a cloud-init ISO.
    greenprint "💿 Creating a cloud-init ISO"
    CLOUD_INIT_PATH="${LIBVIRT_IMAGE_PATH}/seed-${UPGRADE_OS}-raw.iso"
    rm -f "$CLOUD_INIT_PATH"
    pushd "$CLOUD_INIT_DIR"
        sudo mkisofs -o "$CLOUD_INIT_PATH" -V cidata \
            -r -J user-data meta-data > /dev/null 2>&1
    popd
    rm -rf "$CLOUD_INIT_DIR"

    # Ensure SELinux is happy with image.
    greenprint "👿 Running restorecon on image directory"
    sudo restorecon -Rv /var/lib/libvirt/images/

    # Import builder VM
    sudo virt-install --name="$BUILDER_VM_NAME" \
                    --disk path="$GUEST_IMAGE_PATH",format=qcow2 \
                    --disk path="$CLOUD_INIT_PATH",device=cdrom \
                    --memory 3072 \
                    --vcpus 2 \
                    --network network=integration \
                    --os-variant "$OS_VARIANT" \
                    --boot uefi \
                    --import \
                    --noautoconsole \
                    --wait=-1 \
                    --noreboot

    # Start VM.
    greenprint "Start VM"
    sudo virsh start "$BUILDER_VM_NAME"

    # Wait until VM has IP addr from dhcp server
    greenprint "Wait until VM's IP"
    while ! sudo virsh domifaddr "$BUILDER_VM_NAME" | grep ipv4 > /dev/null;
    do
        sleep 5
        echo "Booting..."
    done

    # Get VM IP address
    greenprint "Get VM IP address"
    BUILDER_VM_IP=$(sudo virsh domifaddr "$BUILDER_VM_NAME" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

    # Check for ssh ready to go.
    greenprint "🛃 Checking for SSH is ready to go"
    for _ in $(seq 0 30); do
        RESULTS=$(wait_for_ssh_up "$BUILDER_VM_IP")
        if [[ $RESULTS == 1 ]]; then
            echo "SSH is ready now! 🥳"
            break
        fi
        sleep 10
    done

    # Wait for cloud-init finished.
    greenprint "🛃 Wait for cloud-init finished"
    for _ in $(seq 0 30); do
        RESULTS=$(wait_for_cloud_init "$BUILDER_VM_IP")
        if [[ $RESULTS == 1 ]]; then
            echo "Cloud-init finished! 🥳"
            break
        fi
        sleep 10
    done
else
    UPGRADE_OSTREE_REF="$OSTREE_REF"
fi

##################################################
##
## ostree image/commit upgrade
##
##################################################

# Write a blueprint for ostree image.
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
name = "sssd"
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

# Create inventory file
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[builder]
${BUILDER_VM_IP}
[builder:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Build edge/iot-commit upgrade image
# Test --url arg following by URL without tailling slash for bz#1942029
if [ "$UPGRADE_OSTREE_REF" == "$OSTREE_REF" ]; then
    sudo podman run --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:"${ARCH}" ansible-playbook -v -i /tmp/inventory -e upgrade="true" -e image_type="$CONTAINER_IMAGE_TYPE" -e ostree_ref="$UPGRADE_OSTREE_REF" -e repo_url="$PROD_REPO_URL" build-image.yaml || RESULTS=0
else
    sudo podman run --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:"${ARCH}" ansible-playbook -v -i /tmp/inventory -e rebase="true" -e image_type="$CONTAINER_IMAGE_TYPE" -e ostree_ref="$UPGRADE_OSTREE_REF" -e parent_ref="$OSTREE_REF" -e repo_url="$PROD_REPO_URL" build-image.yaml || RESULTS=0
fi

# Copy image back from builder VM.
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-container.tar" "${TEMPDIR}/edge-container.tar"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.tar'

# Remove cloud-init ISO.
sudo rm -f "$CLOUD_INIT_PATH"

# Deal with rhel-edge container
greenprint "🗜 Extracting and running the image"
sudo podman pull "oci-archive:${TEMPDIR}/edge-container.tar"
sudo podman images
# Clear image file
sudo rm -f "${TEMPDIR}/edge-container.tar"
# Get image id to run image
EDGE_IMAGE_ID=$(sudo podman images --filter "dangling=true" --format "{{.ID}}")
sudo podman run -d --name "${UPGRADE_OS}-raw" --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' "${UPGRADE_OS}-raw")" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod repo
if [ "$UPGRADE_OSTREE_REF" == "$OSTREE_REF" ]; then
    sudo ostree --repo="$RAW_HTTPD_PATH" pull --mirror edge-stage "$OSTREE_REF"
    sudo ostree --repo="$RAW_HTTPD_PATH" static-delta generate "$OSTREE_REF"
    sudo ostree --repo="$RAW_HTTPD_PATH" summary -u
else
    sudo ostree --repo="$RAW_HTTPD_PATH" pull --mirror edge-stage "$UPGRADE_OSTREE_REF"
fi
# Get ostree commit value.
greenprint "🕹 Get ostree upgrade commit value"
UPGRADE_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${UPGRADE_OSTREE_REF}")

if [[ "$TEST_OS" == "fedora-37" ]] || [[ "$TEST_OS" == "fedora-38" ]]; then
    # The Fedora IoT Raw image sets the fedora-iot remote URL to https://ostree.fedoraproject.org/iot
    # Replacing with our own local repo
    greenprint "Replacing default remote"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_RAW_VM_IP}" "echo ${EDGE_USER_PASSWORD} | sudo -S ostree remote delete ${ANSIBLE_OS_NAME}"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_RAW_VM_IP}" "echo ${EDGE_USER_PASSWORD} | sudo -S ostree remote add --no-gpg-verify ${REF_PREFIX} ${PROD_REPO_URL}"
fi

if [ "$UPGRADE_OSTREE_REF" == "$OSTREE_REF" ]; then
    # Upgrade
    greenprint "🗳 Upgrade ostree image/commit"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_RAW_VM_IP}" "echo ${EDGE_USER_PASSWORD} | sudo -S rpm-ostree upgrade"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_RAW_VM_IP}" "echo ${EDGE_USER_PASSWORD} | nohup sudo -S systemctl reboot &>/dev/null & exit"
else
    # Rebase
    greenprint "Rebase ostree image/commit"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_RAW_VM_IP}" "echo ${EDGE_USER_PASSWORD} | sudo -S rpm-ostree rebase ${REF_PREFIX}:${UPGRADE_OSTREE_REF}"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_RAW_VM_IP}" "echo ${EDGE_USER_PASSWORD} | nohup sudo -S systemctl reboot &>/dev/null & exit"
fi

# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_RAW_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_RAW_VM_IP}" "echo ${EDGE_USER_PASSWORD} | nohup sudo -S systemctl reboot &>/dev/null & exit"

# Sleep 10 seconds here to make sure vm restarted already
sleep 10
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_RAW_VM_IP")
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
${EDGE_RAW_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
sudo podman run --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:"${ARCH}" ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${UPGRADE_HASH}" -e ostree_ref="${REF_PREFIX}:${UPGRADE_OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" check-ostree.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0
