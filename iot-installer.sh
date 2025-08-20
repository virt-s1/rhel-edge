#!/usr/bin/env bash
set -euox pipefail

# Color output definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    log_info "Cleaning up..."
    
    # Remove temporary directory
    if [[ -d "${TEMPDIR}" ]]; then
        rm -rf "${TEMPDIR}"
    fi
    
    # Stop and undefine VM if it exists
    if virsh list --all --name | grep -q "iot-${TEST_UUID}"; then
        log_info "Stopping and removing VM: iot-${TEST_UUID}"
        virsh destroy "iot-${TEST_UUID}" 2>/dev/null || true
        virsh undefine "iot-${TEST_UUID}" --nvram 2>/dev/null || true
    fi
    
    # Remove disk image
    local disk_image="/var/lib/libvirt/images/iot-${TEST_UUID}.qcow2"
    if [[ -f "${disk_image}" ]]; then
        rm -f "${disk_image}"
    fi
    
    exit "${exit_code}"
}

# Set trap to cleanup on exit
trap cleanup EXIT INT TERM

# Validate required environment variable
if [[ -z "${COMPOSE:-}" ]]; then
    log_error "COMPOSE environment variable is not set"
    exit 1
fi

# Provision the software under test
./iot-setup.sh

# Get OS data
source /etc/os-release
ARCH=$(uname -m)
TEST_UUID=$(uuidgen)
TEMPDIR=$(mktemp -d)
GUEST_IP=192.168.100.50
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY="key/ostree_key"
SSH_KEY_PUB=$(cat "${SSH_KEY}.pub")
COMPOSE_URL="https://kojipkgs.fedoraproject.org/compose/iot/${COMPOSE}/compose/IoT/${ARCH}/iso"
COMPOSE_ID=$(echo "${COMPOSE}" | cut -d- -f4)

case "${ID}-${VERSION_ID}" in
    "fedora-42")
        OSTREE_REF="fedora/stable/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        IMAGE_FILENAME="Fedora-IoT-ostree-42-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-43")
        OSTREE_REF="fedora/devel/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        IMAGE_FILENAME="Fedora-IoT-ostree-43-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-44")
        OSTREE_REF="fedora/rawhide/${ARCH}/iot"
        OS_VARIANT="fedora-rawhide"
        IMAGE_FILENAME="Fedora-IoT-ostree-44-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    *)
        log_error "Unsupported distro: ${ID}-${VERSION_ID}"
        exit 1
        ;;
esac

modksiso() {
    local isomount kspath iso newiso ksfiles ksfile ksbase newksfile oldks
    isomount=$(mktemp -d)
    kspath=$(mktemp -d)
    iso="$1"
    newiso="$2"

    if [[ -f "${newiso}" ]]; then
        log_info "Image already exists, skipping mkksiso"
        return 0
    fi

    log_info "Mounting ${iso} -> ${isomount}"
    sudo mount -v -o ro "${iso}" "${isomount}"

    readarray -t ksfiles < <(find "${isomount}" -maxdepth 1 -name '*.ks' -print)
    if [[ ${#ksfiles[@]} -eq 0 ]]; then
        log_error "No kickstart file found in ISO"
        exit 1
    fi
    ksfile="${ksfiles[0]}"
    log_info "Found kickstart file: ${ksfile}"

    ksbase=$(basename "${ksfile}")
    newksfile="${kspath}/${ksbase}"
    oldks=$(cat "${ksfile}")
    cat > "${newksfile}" << EOFKS
text
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
bootloader --append="console=tty0 console=ttyS0,115200n8"
user --name=admin --groups=wheel --iscrypted --password=\$6\$1LgwKw9aOoAi/Zy9\$Pn3ErY1E8/yEanJ98evqKEW.DZp24HTuqXPJl6GYCm8uuobAmwxLv7rGCvTRZhxtcYdmC0.XnYRSR9Sh6de3p0
sshkey --username=admin "${SSH_KEY_PUB}"
${oldks}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
echo 'admin ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
echo 'installeruser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
%end
EOFKS

    log_info "Writing new ISO"
    sudo mkksiso -c "console=ttyS0,115200" --rm-args "quiet" "${newksfile}" "${iso}" "${newiso}"

    log_info "==== NEW KICKSTART FILE ===="
    cat "${newksfile}"
    log_info "============================"
}

# Download OS image
download_image() {
    log_info "Downloading OS image..."
    
    local image_url="${COMPOSE_URL}/${IMAGE_FILENAME}"
    
    if [[ -f "${IMAGE_FILENAME}" ]]; then
        log_info "Image already exists, skipping download"
        return 0
    fi
    
    if ! sudo wget --progress=bar:force "${image_url}"; then
        log_error "Failed to download image from ${image_url}"
        exit 1
    fi
    
    if [[ -f "${IMAGE_FILENAME}" ]]; then
        log_success "Download completed: ${IMAGE_FILENAME}"
    else
        log_error "Downloaded file not found: ${IMAGE_FILENAME}"
        exit 1
    fi
}

# Wait for SSH to be available
wait_for_ssh() {
    local ip_address=$1
    local max_attempts=30
    local attempt=0
    
    log_info "Waiting for SSH on ${ip_address}..."
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${ip_address}" 'echo -n "READY"' 2>/dev/null | grep -q "READY"; then
            log_success "SSH is ready"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 10
    done
    
    log_error "SSH connection timed out after $((max_attempts * 10)) seconds"
    return 1
}

# Main execution

log_info "Starting fedora IoT simplified installer test"
log_info "Test UUID: ${TEST_UUID}"
log_info "Temporary directory: ${TEMPDIR}"

download_image
modksiso "${IMAGE_FILENAME}" "/var/lib/libvirt/images/${IMAGE_FILENAME}"

virt-install --name="iot-${TEST_UUID}" \
    --disk path="/var/lib/libvirt/images/iot-${TEST_UUID}.qcow2",size=20,format=qcow2 \
    --ram 4096 \
    --vcpus 2 \
    --network network=integration,mac=34:49:22:B0:83:30 \
    --os-variant "${OS_VARIANT}" \
    --cdrom "/var/lib/libvirt/images/${IMAGE_FILENAME}" \
    --boot uefi \
    --nographics \
    --noautoconsole \
    --wait=-1 \
    --noreboot

log_info "Starting VM..."
sudo virsh start "iot-${TEST_UUID}"

# Wait for SSH
if ! wait_for_ssh "${GUEST_IP}"; then
    exit 1
fi

# Create Ansible inventory
log_info "Creating Ansible inventory..."
tee "${TEMPDIR}/inventory" > /dev/null << EOF
[ostree_guest]
${GUEST_IP}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes
ansible_become_method=sudo
ansible_become_pass=foobar
EOF

# Run Ansible playbook
log_info "Running Ansible playbook..."
if ! ansible-playbook -v -i "${TEMPDIR}/inventory" -e fdo_credential="false" -e ostree_ref="fedora-iot:${OSTREE_REF}" check-ostree-iot.yaml; then
    log_error "Ansible playbook check failed"
    exit 1
fi

log_success "Test completed successfully"

exit 0
