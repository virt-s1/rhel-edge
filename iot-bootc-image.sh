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
    if sudo virsh list --all --name | grep -q "iot-bootc-image-${TEST_UUID}"; then
        log_info "Stopping and removing VM: iot-bootc-image-${TEST_UUID}"
        sudo virsh destroy "iot-bootc-image-${TEST_UUID}" 2>/dev/null || true
        sudo virsh undefine "iot-bootc-image-${TEST_UUID}" --nvram 2>/dev/null || true
    fi

    # Remove disk image folder
    sudo rm -rf output

    # Remove container images
    sudo podman rmi -a -f

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
EDGE_USER=core
EDGE_USER_PASSWORD=foobar
COMPOSE_URL="https://kojipkgs.fedoraproject.org/compose/iot/${COMPOSE}/compose/IoT/${ARCH}/images"
COMPOSE_ID=$(echo "${COMPOSE}" | cut -d- -f4)

CONTAINER_IMG_NAME=fedora-iot-bootc
# QUAY_REPO_URL="quay.io/${QUAY_USERNAME}/${CONTAINER_IMG_NAME}"
# QUAY_REPO_TAG="${QUAY_REPO_URL}:${VERSION_ID}"
BOOTC_SYSTEM="true"

# Set OS-specific variables
case "${ID}-${VERSION_ID}" in
    "fedora-43")
        OS_VARIANT="fedora-unknown"
        OCI_ARCHIVE="Fedora-IoT-bootc-${ARCH}-43.${COMPOSE_ID}.ociarchive"
        ;;
    "fedora-44")
        OS_VARIANT="fedora-unknown"
        OCI_ARCHIVE="Fedora-IoT-bootc-${ARCH}-44.${COMPOSE_ID}.ociarchive"
        ;;
    *)
        log_error "Unsupported distro: ${ID}-${VERSION_ID}"
        exit 1
        ;;
esac

# Download OS image
download_image() {
    log_info "Downloading OS image..."

    local image_url="${COMPOSE_URL}/${OCI_ARCHIVE}"
    if [[ -f "${OCI_ARCHIVE}" ]]; then
        log_info "Container image already exists, skipping download"
        return 0
    fi
    
    if ! sudo wget --progress=bar:force "${image_url}"; then
        log_error "Failed to download image from ${image_url}"
        exit 1
    fi

    if [[ -f "${OCI_ARCHIVE}" ]]; then
        log_success "Download completed: ${OCI_ARCHIVE}"
    else
        log_error "Downloaded file not found: ${OCI_ARCHIVE}"
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
log_info "Starting fedora IoT bootc image test"
log_info "Test UUID: ${TEST_UUID}"
log_info "Temporary directory: ${TEMPDIR}"

# Execute steps
download_image

# Container image settings
OCI_ARCHIVE_TAG="${VERSION_ID}"

log_info "Copying container image into storage with a controlled tag"
sudo skopeo copy oci-archive:"${OCI_ARCHIVE}" containers-storage:"${CONTAINER_IMG_NAME}:${OCI_ARCHIVE_TAG}"

log_info "Preparing bib configuration file..."
tee config.json > /dev/null << EOF
{
  "blueprint": {
    "customizations": {
      "user": [
        {
          "name": "${EDGE_USER}",
          "password": "${EDGE_USER_PASSWORD}",
          "key": "${SSH_KEY_PUB}",
          "groups": [
            "wheel"
          ]
        }
      ]
    }
  }
}
EOF

# Prepare output folder
mkdir -pv output

log_info "Generating disk image using bib..."
sudo podman run \
     --rm \
     -it \
     --privileged \
     --pull=newer \
     --security-opt label=type:unconfined_t \
     -v "$(pwd)"/config.json:/config.json \
     -v "$(pwd)"/output:/output \
     -v /var/lib/containers/storage:/var/lib/containers/storage \
     quay.io/centos-bootc/bootc-image-builder:latest \
     --type qcow2 \
     --local \
     --config /config.json \
     --rootfs xfs \
     --use-librepo=true \
     "${CONTAINER_IMG_NAME}:${OCI_ARCHIVE_TAG}"
     # "${QUAY_REPO_TAG}"

log_info "Starting VM installation..."
sudo mv ./output/qcow2/disk.qcow2 /var/lib/libvirt/images/"${TEST_UUID}"-disk.qcow2
LIBVIRT_IMAGE_PATH=/var/lib/libvirt/images/${TEST_UUID}-disk.qcow2
sudo restorecon -Rv /var/lib/libvirt/images/

sudo virt-install  --name="iot-bootc-image-${TEST_UUID}"\
                   --disk path="${LIBVIRT_IMAGE_PATH}",format=qcow2 \
                   --ram 4096 \
                   --vcpus 4 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-type linux \
                   --os-variant ${OS_VARIANT} \
                   --boot "uefi" \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --import \
                   --noreboot

log_info "Starting VM..."
sudo virsh start "iot-bootc-image-${TEST_UUID}"

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
if ! sudo ansible-playbook -v -i "${TEMPDIR}/inventory" -e bootc_system="${BOOTC_SYSTEM}" check-ostree-iot.yaml; then
    log_error "Ansible playbook check failed"
    exit 1
fi

log_success "Test completed successfully"

exit 0
