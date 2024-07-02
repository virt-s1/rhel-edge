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

# modify existing kickstart by prepending and appending commands
function modksiso {
    isomount=$(mktemp -d)
    kspath=$(mktemp -d)

    iso="$1"
    newiso="$2"

    echo "Mounting ${iso} -> ${isomount}"
    sudo mount -v -o ro "${iso}" "${isomount}"

    cleanup() {
        sudo umount -v "${isomount}"
        rmdir -v "${isomount}"
        rm -rv "${kspath}"
    }

    trap cleanup RETURN

    ksfiles=("${isomount}"/*.ks)
    ksfile="${ksfiles[0]}"  # there shouldn't be more than one anyway
    echo "Found kickstart file ${ksfile}"

    ksbase=$(basename "${ksfile}")
    newksfile="${kspath}/${ksbase}"
    oldks=$(cat "${ksfile}")
    echo "Preparing modified kickstart file"
    cat > "${newksfile}" << EOFKS
text
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
${oldks}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
# no sudo password for user admin and installeruser
echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
echo -e 'installeruser\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
# add remote prod edge repo
ostree remote delete ${ANSIBLE_OS_NAME}
ostree remote add --no-gpg-verify --no-sign-verify ${ANSIBLE_OS_NAME} ${PROD_REPO_URL}
%end
EOFKS

    echo "Writing new ISO"
    sudo mkksiso -c "console=ttyS0,115200" --ks "${newksfile}" "${iso}" "${newiso}"

    echo "==== NEW KICKSTART FILE ===="
    cat "${newksfile}"
    echo "============================"
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"
    # Clear builder vm
    sudo virsh destroy "$BUILDER_VM_NAME"
    sudo virsh undefine "$BUILDER_VM_NAME" --nvram
    sudo virsh vol-delete --pool images "$GUEST_IMAGE_PATH"
    # Clear edge commit vm
    sudo virsh destroy "${EDGE_INSTALLER_VM_NAME}"
    sudo virsh undefine "${EDGE_INSTALLER_VM_NAME}" --nvram
    sudo virsh vol-delete --pool images "$EDGE_INSTALLER_IMAGE_PATH"
    # Remove repo folder.
    sudo rm -rf "$INSTALLER_HTTPD_PATH"
    # Remove any status containers if exist
    sudo podman rm -f -a
    # Remove all images
    sudo podman rmi -f -a
    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"
    # Remove un-used ISO file
    sudo rm -f "/var/lib/libvirt/images/edge-installer.iso"

}

# Variables before case
BOOT_ARGS="uefi"
# Fedora does not support embedded container in ostree commit
EMBEDDED_CONTAINER="true"
# Fedora does not support container image auto uploading
CONTAINER_PUSHING_FEAT="true"
CONTAINER_IMAGE_TYPE=edge-container
INSTALLER_IMAGE_TYPE=edge-installer

# Set up variables.
TEMPDIR=$(mktemp -d)
LIBVIRT_IMAGE_PATH="/var/lib/libvirt/images"
INSTALLER_HTTPD_PATH="/var/www/html/${TEST_OS}-installer"
BUILDER_VM_NAME="${TEST_OS}-installer-builder"
GUEST_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/guest-image-${TEST_OS}-installer.qcow2"
EDGE_INSTALLER_VM_NAME="${TEST_OS}-installer"
EDGE_INSTALLER_IMAGE_PATH="${LIBVIRT_IMAGE_PATH}/${TEST_OS}-installer.qcow2"
BLUEPRINT_FILE="${TEMPDIR}/blueprint.toml"
QUAY_CONFIG="${TEMPDIR}/quay_config.toml"
QUAY_REPO_URL="docker://quay.io/rhel-edge/edge-containers"
QUAY_REPO_TAG=$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')
# Omit the "docker://" prefix at QUAY_REPO_URL
QUAY_REPO_URL_AUX=$(echo ${QUAY_REPO_URL} | grep -oP '(quay.*)')
QUAY_REPO="${QUAY_REPO_URL_AUX}:${QUAY_REPO_TAG}"
PROD_REPO_ADDRESS=192.168.100.1
PROD_REPO_URL="http://${PROD_REPO_ADDRESS}/${TEST_OS}-installer"
PROD_REPO_URL_2="${PROD_REPO_URL}/"
STAGE_REPO_ADDRESS=192.168.200.1
STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"
ANSIBLE_USER="installeruser"
DIRS_FILES_CUSTOMIZATION="true"
# Mount /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
# It's RHEL 9.2 and above, CS9, Fedora 37 and above ONLY
SYSROOT_RO="false"
FEDORA_IMAGE_DIGEST="sha256:8fd6ac4c552bbec7910df7b0625310561d56513ecbcc418825a2f5635efecfab"
FEDORA_LOCAL_NAME="localhost/fedora-aarch64:v1"

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
        ANSIBLE_OS_NAME="rhel"
        ;;
    "rhel-9-3")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-3-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.93 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel9-unknown"
        OSTREE_REF="rhel/9/${ARCH}/edge"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.3.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.3-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="rhel"
        SYSROOT_RO="true"
        ;;
    "rhel-9-4")
        sed -i "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g" files/rhel-9-4-0.json
        sed "s/REPLACE_ME_HERE/${DOWNLOAD_NODE}/g; s/REPLACE_ARCH_HERE/${ARCH}/g" tools/user-data.arch.94 | sudo tee "${CLOUD_INIT_DIR}/user-data"
        OS_VARIANT="rhel9-unknown"
        OSTREE_REF="rhel/9/${ARCH}/edge"
        GUEST_IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">rhel-guest-image-9.4-.*.qcow2<" | tr -d '><')
        ANSIBLE_OS_NAME="rhel"
        SYSROOT_RO="true"
        ;;
    "centos-stream-8")
        OS_VARIANT="centos-stream8"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="centos/8/${ARCH}/edge"
        GUEST_IMAGE_URL="https://odcs.stream.centos.org/stream-8/production/latest-CentOS-Stream/compose/BaseOS/aarch64/images/"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-8-.*.qcow2<" | tr -d '><' | tail -1)
        ANSIBLE_OS_NAME="rhel"
        ;;
    "centos-stream-9")
        OS_VARIANT="centos-stream9"
        cp tools/user-data "$CLOUD_INIT_DIR"
        OSTREE_REF="centos/9/${ARCH}/edge"
        GUEST_IMAGE_URL="https://odcs.stream.centos.org/production/latest-CentOS-Stream/compose/BaseOS/aarch64/images"
        GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">CentOS-Stream-GenericCloud-9-.*.qcow2<" | tr -d '><')
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        ANSIBLE_OS_NAME="rhel"
        SYSROOT_RO="true"
        ;;
    "fedora-39")
         OS_VARIANT="fedora-unknown"
         cp tools/user-data "$CLOUD_INIT_DIR"
         OSTREE_REF="fedora/39/${ARCH}/iot"
         CONTAINER_IMAGE_TYPE=iot-container
         INSTALLER_IMAGE_TYPE=iot-installer
         GUEST_IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/aarch64/images"
         GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-39.*.qcow2<" | tr -d '><')
         EMBEDDED_CONTAINER="false"
         CONTAINER_PUSHING_FEAT="false"
         QUAY_REPO=""
         ANSIBLE_OS_NAME="fedora"
         SYSROOT_RO="true"
         ;;
     "fedora-40")
         OS_VARIANT="fedora-unknown"
         cp tools/user-data "$CLOUD_INIT_DIR"
         OSTREE_REF="fedora/40/${ARCH}/iot"
         CONTAINER_IMAGE_TYPE=iot-container
         INSTALLER_IMAGE_TYPE=iot-installer
         GUEST_IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/aarch64/images"
         GUEST_IMAGE_NAME=$(curl -s "${GUEST_IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-Generic\.aarch64.*.qcow2<" | tr -d '><')
         EMBEDDED_CONTAINER="false"
         CONTAINER_PUSHING_FEAT="false"
         QUAY_REPO=""
         ANSIBLE_OS_NAME="fedora"
         SYSROOT_RO="true"
         ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Prepare ostree prod repo and configure stage repo
greenprint "Prepare ostree prod repo and configure stage repo"
sudo rm -rf "$INSTALLER_HTTPD_PATH"
sudo mkdir -p "$INSTALLER_HTTPD_PATH"
sudo ostree --repo="$INSTALLER_HTTPD_PATH" init --mode=archive
sudo ostree --repo="$INSTALLER_HTTPD_PATH" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"

# Download guest image
sudo curl --no-progress-meter -o "${GUEST_IMAGE_PATH}" "${GUEST_IMAGE_URL}/${GUEST_IMAGE_NAME}"
# Extend to 15G for image building required
sudo qemu-img resize "${GUEST_IMAGE_PATH}" 20G

# Set up a cloud-init ISO.
greenprint "💿 Creating a cloud-init ISO"
CLOUD_INIT_PATH="${LIBVIRT_IMAGE_PATH}/seed-installer.iso"
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
                  --memory 4096 \
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
## build edge-container image
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
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/admin/"
groups = ["wheel"]
EOF

# Fedora does not support embedded container in commit
if [[ "${EMBEDDED_CONTAINER}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[containers]]
source = "quay.io/fedora/fedora:latest"

[[containers]]
source = "registry.gitlab.com/redhat/edge/rhel-edge/fedora-aarch64@${FEDORA_IMAGE_DIGEST}"
name = "${FEDORA_LOCAL_NAME}"
EOF
fi

if [[ $CONTAINER_PUSHING_FEAT == "true" ]]; then
    # Write the registry configuration.
    greenprint "📄 Preparing quay.io config to push image"
    tee "$QUAY_CONFIG" > /dev/null << EOF
provider = "container"
[settings]
username = "$QUAY_USERNAME"
password = "$QUAY_PASSWORD"
EOF
fi

# Add directory and files customization, and services customization for testing
if [[ "${DIRS_FILES_CUSTOMIZATION}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.directories]]
path = "/etc/custom_dir/dir1"
user = 1020
group = 1020
mode = "0770"
ensure_parents = true

[[customizations.files]]
path = "/etc/systemd/system/custom.service"
data = "[Unit]\nDescription=Custom service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/false\n[Install]\nWantedBy=multi-user.target\n"

[[customizations.files]]
path = "/etc/custom_file.txt"
data = "image builder is the best\n"

[[customizations.directories]]
path = "/etc/systemd/system/custom.service.d"

[[customizations.files]]
path = "/etc/systemd/system/custom.service.d/override.conf"
data = "[Service]\nExecStart=\nExecStart=/usr/bin/cat /etc/custom_file.txt\n"

[customizations.services]
enabled = ["custom.service"]
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
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e image_type="$CONTAINER_IMAGE_TYPE" -e quay_repo="$QUAY_REPO" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

# For fedora which does not support auto uploading container image
if [[ $CONTAINER_PUSHING_FEAT == "false" ]]; then
    # Copy image back from builder VM.
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-container.tar" "${TEMPDIR}/edge-container.tar"

    # Remove image in builder VM
    ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.tar'

    # Upload container image to quay.io
    greenprint "Uploading image to quay.io"
    sudo skopeo copy --dest-creds "${QUAY_USERNAME}:${QUAY_PASSWORD}" "oci-archive:${TEMPDIR}/edge-container.tar" "${QUAY_REPO_URL}:${QUAY_REPO_TAG}"

    sudo rm -f "${TEMPDIR}/edge-container.tar"
fi

# Remove cloud-init ISO.
sudo rm -f "$CLOUD_INIT_PATH"

# Run container image as stage repo
sudo podman run -d --name "${TEST_OS}-installer" --network edge --ip "$STAGE_REPO_ADDRESS" "${QUAY_REPO_URL}:${QUAY_REPO_TAG}"
# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' "${TEST_OS}-installer")" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod repo
sudo ostree --repo="$INSTALLER_HTTPD_PATH" pull --mirror edge-stage "$OSTREE_REF"

# Clean container env
sudo podman rm -f "${TEST_OS}-installer"
sudo podman rmi "${QUAY_REPO_URL_AUX}:${QUAY_REPO_TAG}"

# Clean tag from quay.io
greenprint "Remove tag from quay.io repo"
skopeo delete --creds "${QUAY_USERNAME}:${QUAY_PASSWORD}" "${QUAY_REPO_URL}:${QUAY_REPO_TAG}"

##################################################
##
## build edge-installer image
##
##################################################
# Write a blueprint for installer image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "installer"
description = "A base rhel-edge installer image"
version = "0.0.1"
modules = []
groups = []
[[customizations.user]]
name = "${ANSIBLE_USER}"
description = "Added by installer blueprint"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/installeruser/"
groups = ["wheel"]
EOF

# Build edge/iot-container image.
# Test --url arg following by URL with tailling slash for bz#1942029
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e image_type="$INSTALLER_IMAGE_TYPE" -e repo_url="$PROD_REPO_URL_2" -e ostree_ref="$OSTREE_REF" build-image.yaml || RESULTS=0

# Copy image back from builder VM.
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "${SSH_USER}@${BUILDER_VM_IP}:/home/admin/*-installer.iso" "${TEMPDIR}/edge-installer.iso"

# Remove image in builder VM
ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${BUILDER_VM_IP}" 'rm -f /home/admin/*.iso'

# Inject ks file into ISO
modksiso "${TEMPDIR}/edge-installer.iso" "/var/lib/libvirt/images/edge-installer.iso"
sudo rm -f "${TEMPDIR}/edge-installer.iso"

# UEFI installation test
# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt install"
sudo qemu-img create -f qcow2 "${EDGE_INSTALLER_IMAGE_PATH}" 20G

# Install ostree image via ISO on UEFI vm
greenprint "💿 Install ostree image via installer(ISO) on UEFI vm"
sudo virt-install  --name="${EDGE_INSTALLER_VM_NAME}" \
                   --disk path="${EDGE_INSTALLER_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --cdrom "/var/lib/libvirt/images/edge-installer.iso" \
                   --boot ${BOOT_ARGS} \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${EDGE_INSTALLER_VM_NAME}"

# Wait until VM has IP addr from dhcp server
greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "${EDGE_INSTALLER_VM_NAME}" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

# Get VM IP address
greenprint "Get VM IP address"
EDGE_INSTALLER_VM_IP=$(sudo virsh domifaddr "${EDGE_INSTALLER_VM_NAME}" | grep ipv4 | awk '{print $4}' | sed 's/\/24//')

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_INSTALLER_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${EDGE_INSTALLER_VM_IP}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10
# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_INSTALLER_VM_IP")
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
${EDGE_INSTALLER_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${ANSIBLE_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${OSTREE_HASH}" -e ostree_ref="${ANSIBLE_OS_NAME}:${OSTREE_REF}" -e embedded_container="$EMBEDDED_CONTAINER" -e sysroot_ro="$SYSROOT_RO" -e test_custom_dirs_files="${DIRS_FILES_CUSTOMIZATION}" check-ostree.yaml || RESULTS=0
check_result

##################################################
##
## ostree image/commit upgrade
##
##################################################

# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "upgrade"
description = "An upgrade ostree image"
version = "0.0.2"
modules = []
groups = []
[[packages]]
name = "python3"
version = "*"
[[packages]]
name = "wget"
version = "*"
EOF

# Fedora does not support embedded container in commit
if [[ "${EMBEDDED_CONTAINER}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[containers]]
source = "quay.io/fedora/fedora:latest"

[[containers]]
source = "registry.gitlab.com/redhat/edge/rhel-edge/fedora-aarch64@${FEDORA_IMAGE_DIGEST}"
name = "${FEDORA_LOCAL_NAME}"
EOF
fi

if [[ "${DIRS_FILES_CUSTOMIZATION}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.directories]]
path = "/etc/custom_dir/dir1"
user = 1020
group = 1020
mode = "0770"
ensure_parents = true

[[customizations.files]]
path = "/etc/systemd/system/custom.service"
data = "[Unit]\nDescription=Custom service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/false\n[Install]\nWantedBy=multi-user.target\n"

[[customizations.files]]
path = "/etc/custom_file.txt"
data = "image builder is the best\n"

[[customizations.directories]]
path = "/etc/systemd/system/custom.service.d"

[[customizations.files]]
path = "/etc/systemd/system/custom.service.d/override.conf"
data = "[Service]\nExecStart=\nExecStart=/usr/bin/cat /etc/custom_file.txt\n"

[customizations.services]
enabled = ["custom.service"]
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
sudo podman run -d --name "${TEST_OS}-installer" --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' "${TEST_OS}-installer")" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod repo
sudo ostree --repo="$INSTALLER_HTTPD_PATH" pull --mirror edge-stage "$OSTREE_REF"
sudo ostree --repo="$INSTALLER_HTTPD_PATH" static-delta generate "$OSTREE_REF"
sudo ostree --repo="$INSTALLER_HTTPD_PATH" summary -u

# Get ostree commit value.
greenprint "🕹 Get ostree upgrade commit value"
UPGRADE_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

# Upgrade image/commit.
greenprint "Upgrade ostree image/commit"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_INSTALLER_VM_IP}" 'sudo rpm-ostree upgrade'
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${EDGE_INSTALLER_VM_IP}" 'nohup sudo systemctl reboot &>/dev/null & exit'

# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
# shellcheck disable=SC2034  # Unused variables left for readability
for _ in $(seq 0 30); do
    RESULTS=$(wait_for_ssh_up "$EDGE_INSTALLER_VM_IP")
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check ostree upgrade result
check_result

# Add instance IP address into /etc/ansible/hosts
# Test user installeruser added by edge-installer bp
# User installer still exists after upgrade but upgrade bp does not contain installeruer
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${EDGE_INSTALLER_VM_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${ANSIBLE_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 --network edge -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:aarch64 ansible-playbook -v -i /tmp/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${UPGRADE_HASH}" -e ostree_ref="${ANSIBLE_OS_NAME}:${OSTREE_REF}" -e embedded_container="$EMBEDDED_CONTAINER" -e sysroot_ro="$SYSROOT_RO" -e test_custom_dirs_files="${DIRS_FILES_CUSTOMIZATION}" check-ostree.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0
