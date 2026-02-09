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

    # Remove ignition directory
    if [[ -d "/var/www/html/ignition" ]]; then
        sudo rm -rf "/var/www/html/ignition"
    fi

    # Stop and undefine VM if it exists
    if sudo virsh list --all --name | grep -q "iot-${TEST_UUID}"; then
        log_info "Stopping and removing VM: iot-${TEST_UUID}"
        sudo virsh destroy "iot-${TEST_UUID}" 2>/dev/null || true
        sudo virsh undefine "iot-${TEST_UUID}" --nvram 2>/dev/null || true
    fi

    # Remove raw image
    sudo rm -f "/var/lib/libvirt/images/iot-${TEST_UUID}.qcow2"
    sudo rm -f "iot-${TEST_UUID}.qcow2"
    sudo rm -f "${RAW_IMAGE}.qcow2"
    sudo rm -f "Fedora-IoT-raw-${VERSION_ID}-${COMPOSE_ID}.${ARCH}.raw"    

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
GUEST_IP="192.168.100.50"
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY="key/ostree_key"
SSH_KEY_PUB=$(cat "${SSH_KEY}.pub")
EDGE_USER="admin"
EDGE_USER_PASSWORD="foobar"
COMPOSE_URL="https://kojipkgs.fedoraproject.org/compose/iot/${COMPOSE}/compose/IoT/${ARCH}/images"
COMPOSE_ID=$(echo "${COMPOSE}" | cut -d- -f4)
ADD_STORAGE="+10G"

# Set OS-specific variables
case "${ID}-${VERSION_ID}" in
    "fedora-43")
        OSTREE_REF="fedora/stable/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        RAW_IMAGE="Fedora-IoT-raw-43-${COMPOSE_ID}.${ARCH}.raw.xz"
        ;;
    "fedora-44")
        OSTREE_REF="fedora/devel/${ARCH}/iot"
        OS_VARIANT="fedora-rawhide"
        RAW_IMAGE="Fedora-IoT-raw-44-${COMPOSE_ID}.${ARCH}.raw.xz"
        ;;
    *)
        log_error "Unsupported distro: ${ID}-${VERSION_ID}"
        exit 1
        ;;
esac

setup_ignition() {
    log_info "Setting up Ignition configuration..."
    
    local ignition_dir="/var/www/html/ignition"
    local ignition_file="${ignition_dir}/fiot.ign"
    
    [ -d "${ignition_dir}" ] || sudo mkdir -p "${ignition_dir}"
    
    sudo tee "${ignition_file}" > /dev/null << EOF
{
  "ignition": {
    "version": "3.4.0"
  },
  "passwd": {
    "users": [
      {
        "groups": [
          "wheel"
        ],
        "homeDir": "/home/admin",
        "name": "admin",
        "passwordHash": "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl.",
        "shell": "/bin/bash",
        "sshAuthorizedKeys": [
          "$SSH_KEY_PUB"
        ]
      }
    ]
  }
}
EOF
    
    if [[ -f "${ignition_file}" ]]; then
        log_success "Ignition configuration created at ${ignition_file}"
    else
        log_error "Failed to create Ignition configuration"
        exit 1
    fi
}

# Download OS image
download_image() {
    log_info "Downloading OS image..."

    local image_url="${COMPOSE_URL}/${RAW_IMAGE}"
    if [[ -f "${RAW_IMAGE}" ]]; then
        log_info "Container image already exists, skipping download"
        return 0
    fi
    
    if ! sudo wget --progress=bar:force "${image_url}"; then
        log_error "Failed to download image from ${image_url}"
        exit 1
    fi

    if [[ -f "${RAW_IMAGE}" ]]; then
        log_success "Download completed: ${RAW_IMAGE}"
    else
        log_error "Downloaded file not found: ${RAW_IMAGE}"
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
        if ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${EDGE_USER}@${ip_address}" 'echo -n "READY"' 2>/dev/null | grep -q "READY"; then
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
log_info "Starting fedora IoT raw image test"
log_info "Test UUID: ${TEST_UUID}"
log_info "Temporary directory: ${TEMPDIR}"

# Execute steps
download_image
setup_ignition
sudo restorecon -Rv /var/www/html/ignition

sudo xz -d "${RAW_IMAGE}"
sudo qemu-img resize "Fedora-IoT-raw-${VERSION_ID}-${COMPOSE_ID}.${ARCH}.raw" "$ADD_STORAGE"
echo ", +" | sudo sfdisk -N 3 "Fedora-IoT-raw-${VERSION_ID}-${COMPOSE_ID}.${ARCH}.raw"

log_info "Create device-mapper entries for each partition"
sudo kpartx -av "Fedora-IoT-raw-${VERSION_ID}-${COMPOSE_ID}.${ARCH}.raw"

# Mount boot partition
[ -d /tmp/boot ] || sudo mkdir /tmp/boot
sudo mount /dev/mapper/loop0p2 /tmp/boot

log_info "Embedding ignition configuration file into raw image..."
sudo sed -i "s|systemd.condition-first-boot=true|systemd.condition-first-boot=true ignition.firstboot=1 ignition.config.url=http://192.168.100.1/ignition/fiot.ign|g" /tmp/boot/ignition.firstboot

# Umount boot partition
sudo umount /tmp/boot

# Deleting mappings
sudo kpartx -dv "Fedora-IoT-raw-${VERSION_ID}-${COMPOSE_ID}.${ARCH}.raw"

sudo qemu-img convert -f raw "Fedora-IoT-raw-${VERSION_ID}-${COMPOSE_ID}.${ARCH}.raw" -O qcow2 "iot-${TEST_UUID}.qcow2"
sudo cp "iot-${TEST_UUID}.qcow2" "/var/lib/libvirt/images/iot-${TEST_UUID}.qcow2"
sudo restorecon -Rv /var/lib/libvirt/images/

sudo virt-install  --name="iot-${TEST_UUID}" \
                   --disk path="/var/lib/libvirt/images/iot-${TEST_UUID}.qcow2",format=qcow2 \
                   --ram 4096 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-type linux \
                   --os-variant ${OS_VARIANT} \
                   --boot uefi \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --import \
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
ansible_user=${EDGE_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Run Ansible playbook
log_info "Running Ansible playbook..."
if ! sudo ansible-playbook -v -i "${TEMPDIR}/inventory" -e ostree_ref="fedora-iot:${OSTREE_REF}" check-ostree-iot.yaml; then
    log_error "Ansible playbook check failed"
    exit 1
fi

log_success "Test completed successfully"

exit 0

