#!/bin/bash
set -exuo pipefail

# Get TEST_OS from $1
TEST_OS=$1

# Get OS data.
source /etc/os-release

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
    sudo virsh destroy "${EDGE_MINIMAL_VM_NAME}"
    sudo virsh undefine "${EDGE_MINIMAL_VM_NAME}" --nvram
    sudo virsh vol-delete --pool images "$EDGE_MINIMAL_IMAGE_PATH"
    # Remove any status containers if exist
    sudo podman rm -f -a
    # Remove all images
    sudo podman rmi -f -a
    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"

}

# Variables before case
BOOT_ARGS="uefi"
MINIMAL_TYPE=minimal-raw
MINIMAL_FILENAME=raw.img

# Set up variables.
TEMPDIR=$(mktemp -d)
LIBVIRT_IMAGE_PATH="/var/lib/libvirt/images"
BUILDER_VM_NAME="${TEST_OS}-minimal-builder"
GUEST_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/guest-image-${TEST_OS}-minimal.qcow2"
EDGE_MINIMAL_VM_NAME="${TEST_OS}-minimal"
EDGE_MINIMAL_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/${TEST_OS}-minimal.qcow2"
BLUEPRINT_FILE="${TEMPDIR}/blueprint.toml"

# Prepare cloud-init data
CLOUD_INIT_DIR=$(mktemp -d)
cp tools/meta-data "$CLOUD_INIT_DIR"

# Set useful things according to different distros.
case "$TEST_OS" in
    "rhel-8-9")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-8-9-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.89 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel8-unknown"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-8/nightly/RHEL-8/latest-RHEL-8.9.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-8.9-.*.qcow2<" | tr -d '><')
        ;;
    "rhel-9-3")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-3-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.93 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel9-unknown"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/updates/RHEL-9/latest-RHEL-9.3.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.3-.*.qcow2<" | tr -d '><')
        ;;
    "rhel-9-4")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-4-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.94 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel9-unknown"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.4-.*.qcow2<" | tr -d '><')
        ;;
    "centos-stream-8")
        OS_VARIANT="centos-stream8"
        cp tools/user-data "$CLOUD_INIT_DIR"
        GUEST_IMAGE_URL="https://cloud.centos.org/centos/8-stream/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-8-.*.qcow2<" | tr -d '><' | tail -1)
        ;;
    "centos-stream-9")
        OS_VARIANT="centos-stream9"
        cp tools/user-data "$CLOUD_INIT_DIR"
        GUEST_IMAGE_URL="https://odcs.stream.centos.org/production/latest-CentOS-Stream/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-9-.*.qcow2<" | tr -d '><')
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        ;;
    "fedora-39")
        OS_VARIANT="fedora-unknown"
        cp tools/user-data "$CLOUD_INIT_DIR"
        GUEST_IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-39.*.qcow2<" | tr -d '><')
        ;;
    "fedora-40")
        OS_VARIANT="fedora-unknown"
        cp tools/user-data "$CLOUD_INIT_DIR"
        GUEST_IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/40/Cloud/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-40.*.qcow2<" | tr -d '><')
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Download guest image
sudo curl --no-progress-meter -o "${GUEST_IMAGE_PATH}" "${GUEST_IMAGE_URL}/${GUEST_IMAGE_NAME}"
# Extend to 15G for image building required
sudo qemu-img resize "${GUEST_IMAGE_PATH}" 15G

# Set up a cloud-init ISO.
greenprint "💿 Creating a cloud-init ISO"
CLOUD_INIT_PATH="${LIBVIRT_IMAGE_PATH}/seed-minimal.iso"
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

############################################################
##
## Build mininal-raw image
##
############################################################

# Write a blueprint for minimal-raw image image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "minimal-raw"
description = "A minimal raw image"
version = "0.0.1"
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
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e image_type="$MINIMAL_TYPE" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-${MINIMAL_FILENAME}" "${TEMPDIR}/${MINIMAL_FILENAME}"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.img'

# Remove cloud-init ISO.
sudo rm -f "$CLOUD_INIT_PATH"

greenprint "Converting the raw image to a qcow2 file"
sudo qemu-img convert -f raw "${TEMPDIR}/${MINIMAL_FILENAME}" -O qcow2 "$EDGE_MINIMAL_IMAGE_PATH"
# Remove raw file
sudo rm -f "${TEMPDIR}/${MINIMAL_FILENAME}"

# UEFI installation test
# Install via raw image on UEFI vm
greenprint "💿 Install via raw image on UEFI vm"
sudo virt-install  --name="${EDGE_MINIMAL_VM_NAME}" \
                   --disk path="${EDGE_MINIMAL_IMAGE_PATH}",format=qcow2 \
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
sudo virsh start "${EDGE_MINIMAL_VM_NAME}"

# Wait until VM has IP addr from dhcp server
greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "${EDGE_MINIMAL_VM_NAME}" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

# Get VM IP address
greenprint "Get VM IP address"
EDGE_MINIMAL_VM_IP=$(sudo virsh domifaddr "${EDGE_MINIMAL_VM_NAME}" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_MINIMAL_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${EDGE_MINIMAL_VM_IP}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10
# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_MINIMAL_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

# Add instance IP address into /etc/ansible/hosts
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${EDGE_MINIMAL_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory check-minimal.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0
