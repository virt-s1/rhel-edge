#!/bin/bash
set -exuo pipefail

# Get TEST_OS from $1
TEST_OS=$1

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

# Wait for FDO onboarding finished.
wait_for_fdo () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${1}" "id -u ${ANSIBLE_USER} > /dev/null 2>&1 && echo -n READY")
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
    sudo virsh destroy "${EDGE_SIMPLIFIED_VM_NAME}"
    sudo virsh undefine "${EDGE_SIMPLIFIED_VM_NAME}" --nvram
    sudo virsh vol-delete --pool images "$EDGE_SIMPLIFIED_IMAGE_PATH"
    # Remove repo folder.
    sudo rm -rf "$SIMPLIFIED_HTTPD_PATH"
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
SIMPLIFIED_IMAGE_TYPE=edge-simplified-installer
SIMPLIFIED_FILENAME="simplified-installer.iso"

# Set up variables.
TEMPDIR=$(mktemp -d)
LIBVIRT_IMAGE_PATH="/var/lib/libvirt/images"
SIMPLIFIED_HTTPD_PATH="/var/www/html/${TEST_OS}-simplified"
BUILDER_VM_NAME="${TEST_OS}-simplified-builder"
GUEST_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/guest-image-${TEST_OS}-simplified.qcow2"
EDGE_SIMPLIFIED_VM_NAME="${TEST_OS}-simplified"
EDGE_SIMPLIFIED_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/${TEST_OS}-simplified.qcow2"
BLUEPRINT_FILE="${TEMPDIR}/blueprint.toml"
PROD_REPO_ADDRESS=192.168.100.1
PROD_REPO_URL="http://${PROD_REPO_ADDRESS}/${TEST_OS}-simplified"
STAGE_REPO_ADDRESS=192.168.200.1
STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"
# Mount /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
# It's RHEL 9.2 and above, CS9, Fedora 37 and above ONLY
SYSROOT_RO="false"
ANSIBLE_USER="admin"

# Prepare cloud-init data
CLOUD_INIT_DIR=$(mktemp -d)
cp tools/meta-data "$CLOUD_INIT_DIR"

# Set useful things according to different distros.
case "$TEST_OS" in
    "rhel-8-9")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-8-9-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.89 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel8-unknown"
        OSTREE_REF="rhel/8/${ARCH}/edge"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-8/nightly/RHEL-8/latest-RHEL-8.9.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-8.9-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        ;;
    "rhel-9-3")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-3-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.93 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel9-unknown"
        OSTREE_REF="rhel/9/${ARCH}/edge"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.3.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.3-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        SYSROOT_RO="true"
        ANSIBLE_USER=fdouser
        ;;
    "rhel-9-4")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-4-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.94 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel9-unknown"
        OSTREE_REF="rhel/9/${ARCH}/edge"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.4-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        SYSROOT_RO="true"
        ANSIBLE_USER=fdouser
        ;;
    "centos-stream-8")
        OS_VARIANT="centos-stream8"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="centos/8/${ARCH}/edge"
        GUEST_IMAGE_URL="https://cloud.centos.org/centos/8-stream/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-8-.*.qcow2<" | tr -d '><' | tail -1)
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        ;;
    "centos-stream-9")
        OS_VARIANT="centos-stream9"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="centos/9/${ARCH}/edge"
        GUEST_IMAGE_URL="https://odcs.stream.centos.org/production/latest-CentOS-Stream/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-9-.*.qcow2<" | tr -d '><')
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        ANSIBLE_OS_NAME="redhat"
        REF_PREFIX="rhel-edge"
        SYSROOT_RO="true"
        ANSIBLE_USER=fdouser
        ;;
    "fedora-39")
        OS_VARIANT="fedora-unknown"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="fedora/39/${ARCH}/iot"
        CONTAINER_IMAGE_TYPE=iot-container
        SIMPLIFIED_IMAGE_TYPE=iot-simplified-installer
        GUEST_IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/aarch64/images/"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-39-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="fedora-iot"
        REF_PREFIX="fedora-iot"
        SYSROOT_RO="true"
        ;;
    "fedora-40")
        OS_VARIANT="fedora-unknown"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="fedora/40/${ARCH}/iot"
        CONTAINER_IMAGE_TYPE=iot-container
        SIMPLIFIED_IMAGE_TYPE=iot-simplified-installer
        GUEST_IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-Generic\.aarch64.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="fedora-iot"
        REF_PREFIX="fedora-iot"
        SYSROOT_RO="true"
        ;;
    "fedora-41")
        OS_VARIANT="fedora-rawhide"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="fedora/41/${ARCH}/iot"
        CONTAINER_IMAGE_TYPE=iot-container
        SIMPLIFIED_IMAGE_TYPE=iot-simplified-installer
        GUEST_IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Cloud/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-Generic\.aarch64.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="fedora-iot"
        REF_PREFIX="fedora-iot"
        SYSROOT_RO="true"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Prepare ostree prod repo and configure stage repo
greenprint "Prepare ostree prod repo and configure stage repo"
sudo rm -rf "$SIMPLIFIED_HTTPD_PATH"
sudo mkdir -p "$SIMPLIFIED_HTTPD_PATH"
sudo ostree --repo="$SIMPLIFIED_HTTPD_PATH" init --mode=archive
sudo ostree --repo="$SIMPLIFIED_HTTPD_PATH" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"

# Download guest image
sudo curl --no-progress-meter -o "${GUEST_IMAGE_PATH}" "${GUEST_IMAGE_URL}/${GUEST_IMAGE_NAME}"
# Extend to 15G for image building required
sudo qemu-img resize "${GUEST_IMAGE_PATH}" 15G

# Set up a cloud-init ISO.
greenprint "💿 Creating a cloud-init ISO"
CLOUD_INIT_PATH="${LIBVIRT_IMAGE_PATH}/seed-simplified.iso"
sudo rm -f "$CLOUD_INIT_PATH"
pushd "$CLOUD_INIT_DIR"
    sudo mkisofs -o $CLOUD_INIT_PATH -V cidata \
        -r -J user-data meta-data > /dev/null 2>&1
popd
sudo rm -rf "$CLOUD_INIT_DIR"

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

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "${SSH_KEY_PUB}"
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

# Build edge/iot-container image.
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e image_type="$CONTAINER_IMAGE_TYPE" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

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
sudo podman run -d --name "${TEST_OS}-simplified" --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' "${TEST_OS}-simplified")" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod repo
greenprint "📡 Sync content from stage repo"
sudo ostree --repo="$SIMPLIFIED_HTTPD_PATH" pull --mirror edge-stage "$OSTREE_REF"

# Clean container env
sudo podman rm -f "${TEST_OS}-simplified"
sudo podman rmi -f "$EDGE_IMAGE_ID"

##########################################################################
##
## build edge/iot-simplified-installer with diun_pub_key_insecure enabled
##
##########################################################################
# Write a blueprint for installer image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "installer"
description = "A rhel-edge simplified-installer image"
version = "0.0.1"
modules = []
groups = []

[customizations]
installation_device = "/dev/vda"

[customizations.fdo]
manufacturing_server_url="http://${BUILDER_VM_IP}:8080"
diun_pub_key_insecure="true"
EOF

# workaround selinux bug https://bugzilla.redhat.com/show_bug.cgi?id=2026795
if [[ "$TEST_OS" == "rhel-9-3" || "$TEST_OS" == "centos-stream-9" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[customizations.kernel]
append = "enforcing=0"
EOF
fi

# Build edge/iot-simplified-installer image.
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e image_type="$SIMPLIFIED_IMAGE_TYPE" -e repo_url="$PROD_REPO_URL" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
sudo scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-${SIMPLIFIED_FILENAME}" "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.iso'

# Wait for fdo server to be running
until [ "$(curl -X POST http://"${BUILDER_VM_IP}":8080/ping)" == "pong" ]; do
    sleep 1;
done;


# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt install"
sudo qemu-img create -f qcow2 "${EDGE_SIMPLIFIED_IMAGE_PATH}" 20G

# UEFI installation test
# Install via simplified installer image on UEFI vm with diun_pub_key_insecure enabled
# The QEMU executable /usr/bin/qemu-system-aarch64 does not support TPM model tpm-crb
greenprint "💿 Install via simplified installer image on UEFI vm"
sudo virt-install  --name="${EDGE_SIMPLIFIED_VM_NAME}" \
                   --disk path="${EDGE_SIMPLIFIED_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --boot ${BOOT_ARGS} \
                   --cdrom "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}" \
                   --tpm backend.type=emulator,backend.version=2.0,model=tpm-tis \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${EDGE_SIMPLIFIED_VM_NAME}"

# Wait until VM has IP addr from dhcp server
greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "${EDGE_SIMPLIFIED_VM_NAME}" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

# Get VM IP address
greenprint "Get VM IP address"
EDGE_SIMPLIFIED_VM_IP=$(sudo virsh domifaddr "${EDGE_SIMPLIFIED_VM_NAME}" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_SIMPLIFIED_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${EDGE_SIMPLIFIED_VM_IP}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10
# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_SIMPLIFIED_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

greenprint "Waiting for FDO user onboarding finished"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_fdo "$EDGE_SIMPLIFIED_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "FDO user is ready to use! 🥳"
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
${EDGE_SIMPLIFIED_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${ANSIBLE_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# FDO user does not have password, use ssh key and no sudo password instead
if [[ "$ANSIBLE_USER" == "fdouser" ]]; then
    sed -i '/^ansible_become_pass/d' "${TEMPDIR}"/inventory
fi


# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${OSTREE_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" -e fdo_credential="true" check-ostree.yaml || RESULTS=0
check_result

# Clean up VM
greenprint "🧹 Clean up VM"
if [[ $(sudo virsh domstate "$EDGE_SIMPLIFIED_VM_NAME") == "running" ]]; then
    sudo virsh destroy "$EDGE_SIMPLIFIED_VM_NAME"
fi
sudo virsh undefine "$EDGE_SIMPLIFIED_VM_NAME" --nvram
sudo virsh vol-delete --pool images "$EDGE_SIMPLIFIED_IMAGE_PATH"

##########################################################################
##
## build edge/iot-simplified-installer with diun_pub_key_hash enabled
##
##########################################################################
# Copy /etc/fdo/aio/keys/diun_cert.pem back
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/etc/fdo/aio/keys/diun_cert.pem" "${TEMPDIR}/diun_cert.pem"
DIUN_PUB_KEY_HASH=sha256:$(openssl x509 -fingerprint -sha256 -noout -in "${TEMPDIR}/diun_cert.pem" | cut -d"=" -f2 | sed 's/://g')

# Write a blueprint for installer image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "fdosshkey"
description = "A rhel-edge simplified-installer image"
version = "0.0.1"
modules = []
groups = []

[customizations]
installation_device = "/dev/vda"

[customizations.fdo]
manufacturing_server_url="http://${BUILDER_VM_IP}:8080"
diun_pub_key_hash="${DIUN_PUB_KEY_HASH}"
EOF

# workaround selinux bug https://bugzilla.redhat.com/show_bug.cgi?id=2026795
if [[ "$TEST_OS" == "rhel-9-3" || "$TEST_OS" == "centos-stream-9" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[customizations.kernel]
append = "enforcing=0"
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

# Build edge/iot-simplified-installer image.
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e image_type="$SIMPLIFIED_IMAGE_TYPE" -e repo_url="$PROD_REPO_URL" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
sudo scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-${SIMPLIFIED_FILENAME}" "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.iso'

# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt install"
sudo qemu-img create -f qcow2 "${EDGE_SIMPLIFIED_IMAGE_PATH}" 20G

# UEFI installation test
# Install via simplified installer image on UEFI vm with diun_pub_key_hash enabled
greenprint "💿 Install via simplified installer image on UEFI vm"
sudo virt-install  --name="${EDGE_SIMPLIFIED_VM_NAME}" \
                   --disk path="${EDGE_SIMPLIFIED_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --boot ${BOOT_ARGS} \
                   --cdrom "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}" \
                   --tpm backend.type=emulator,backend.version=2.0,model=tpm-tis \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${EDGE_SIMPLIFIED_VM_NAME}"

# Wait until VM has IP addr from dhcp server
greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "${EDGE_SIMPLIFIED_VM_NAME}" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

# Get VM IP address
greenprint "Get VM IP address"
EDGE_SIMPLIFIED_VM_IP=$(sudo virsh domifaddr "${EDGE_SIMPLIFIED_VM_NAME}" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_SIMPLIFIED_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${EDGE_SIMPLIFIED_VM_IP}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10
# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_SIMPLIFIED_VM_IP")
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
${EDGE_SIMPLIFIED_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${OSTREE_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" -e fdo_credential="true" check-ostree.yaml || RESULTS=0
check_result

# Clean up VM
greenprint "🧹 Clean up VM"
if [[ $(sudo virsh domstate "$EDGE_SIMPLIFIED_VM_NAME") == "running" ]]; then
    sudo virsh destroy "$EDGE_SIMPLIFIED_VM_NAME"
fi
sudo virsh undefine "$EDGE_SIMPLIFIED_VM_NAME" --nvram
sudo virsh vol-delete --pool images "$EDGE_SIMPLIFIED_IMAGE_PATH"

# Clear simplified installer ISO and cert files
sudo rm -f "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}"
sudo rm -f "${TEMPDIR}/diun_cert.pem"

##########################################################################
##
## build edge/iot-simplified-installer with diun_pub_key_root_certs enabled
##
##########################################################################
# Copy /etc/fdo/aio/keys/diun_cert.pem back
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/etc/fdo/aio/keys/diun_cert.pem" "${TEMPDIR}/diun_cert.pem"
DIUN_PUB_KEY_ROOT_CERTS=$(cat "${TEMPDIR}/diun_cert.pem")

# Write a blueprint for installer image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "fdorootcert"
description = "A rhel-edge simplified-installer image"
version = "0.0.1"
modules = []
groups = []

[customizations]
installation_device = "/dev/vda"

[customizations.fdo]
manufacturing_server_url="http://${BUILDER_VM_IP}:8080"
diun_pub_key_root_certs="""
${DIUN_PUB_KEY_ROOT_CERTS}"""
EOF

# workaround selinux bug https://bugzilla.redhat.com/show_bug.cgi?id=2026795
if [[ "$TEST_OS" == "rhel-9-3" || "$TEST_OS" == "centos-stream-9" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[customizations.kernel]
append = "enforcing=0"
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

# Build edge/iot-simplified-installer image.
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e image_type="$SIMPLIFIED_IMAGE_TYPE" -e repo_url="$PROD_REPO_URL" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
sudo scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-${SIMPLIFIED_FILENAME}" "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.iso'

# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt install"
sudo qemu-img create -f qcow2 "${EDGE_SIMPLIFIED_IMAGE_PATH}" 20G

# UEFI installation test
# Install via simplified installer image on UEFI vm with diun_pub_key_hash enabled
greenprint "💿 Install via simplified installer image on UEFI vm"
sudo virt-install  --name="${EDGE_SIMPLIFIED_VM_NAME}" \
                   --disk path="${EDGE_SIMPLIFIED_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --boot ${BOOT_ARGS} \
                   --cdrom "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}" \
                   --tpm backend.type=emulator,backend.version=2.0,model=tpm-tis \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${EDGE_SIMPLIFIED_VM_NAME}"

# Wait until VM has IP addr from dhcp server
greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "${EDGE_SIMPLIFIED_VM_NAME}" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

# Get VM IP address
greenprint "Get VM IP address"
EDGE_SIMPLIFIED_VM_IP=$(sudo virsh domifaddr "${EDGE_SIMPLIFIED_VM_NAME}" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_SIMPLIFIED_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${EDGE_SIMPLIFIED_VM_IP}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10
# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_SIMPLIFIED_VM_IP")
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
${EDGE_SIMPLIFIED_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${OSTREE_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" -e fdo_credential="true" check-ostree.yaml || RESULTS=0
check_result

# Clear simplified installer ISO and cert files
sudo rm -f "/var/lib/libvirt/images/${SIMPLIFIED_FILENAME}"
sudo rm -f "${TEMPDIR}/diun_cert.pem"

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
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e upgrade="true" -e image_type="$CONTAINER_IMAGE_TYPE" -e ostree_ref="$OSTREE_REF" -e repo_url="$PROD_REPO_URL" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-container.tar" "${TEMPDIR}/edge-container.tar"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.tar'

# Deal with rhel-edge container
greenprint "🗜 Extracting and running the image"
sudo podman pull "oci-archive:${TEMPDIR}/edge-container.tar"
sudo podman images
# Clear image file
sudo rm -f "${TEMPDIR}/edge-container.tar"
# Get image id to run image
EDGE_IMAGE_ID=$(sudo podman images --filter "dangling=true" --format "{{.ID}}")
sudo podman run -d --name "${TEST_OS}-simplified" --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' "${TEST_OS}-simplified")" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod repo
sudo ostree --repo="$SIMPLIFIED_HTTPD_PATH" pull --mirror edge-stage "$OSTREE_REF"
sudo ostree --repo="$SIMPLIFIED_HTTPD_PATH" static-delta generate "$OSTREE_REF"
sudo ostree --repo="$SIMPLIFIED_HTTPD_PATH" summary -u

# Get ostree commit value.
greenprint "🕹 Get ostree upgrade commit value"
UPGRADE_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

if [[ "$TEST_OS" == "fedora-37" ]] || [[ "$TEST_OS" == "fedora-38" ]]; then
    # The Fedora IoT simplified installer image sets the fedora-iot remote URL to https://ostree.fedoraproject.org/iot
    # Replacing with our own local repo
    greenprint "Replacing default remote"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_SIMPLIFIED_VM_IP}" "echo ${EDGE_USER_PASSWORD} |sudo -S ostree remote delete ${ANSIBLE_OS_NAME}"
    sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_SIMPLIFIED_VM_IP}" "echo ${EDGE_USER_PASSWORD} |sudo -S ostree remote add --no-gpg-verify ${ANSIBLE_OS_NAME} ${PROD_REPO_URL}"
fi

# Upgrade image/commit.
greenprint "🗳 Upgrade ostree image/commit"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_SIMPLIFIED_VM_IP}" "echo ${EDGE_USER_PASSWORD} |sudo -S rpm-ostree upgrade"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_SIMPLIFIED_VM_IP}" "echo ${EDGE_USER_PASSWORD} |nohup sudo -S systemctl reboot &>/dev/null & exit"

# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
# shellcheck disable=SC2034  # Unused variables left for readability
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_SIMPLIFIED_VM_IP")
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
${EDGE_SIMPLIFIED_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${UPGRADE_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e sysroot_ro="$SYSROOT_RO" -e fdo_credential="true" check-ostree.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0
