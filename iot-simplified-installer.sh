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
GUEST_IP="192.168.100.50"
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY="key/ostree_key"
SSH_KEY_PUB=$(cat "${SSH_KEY}.pub")
COMPOSE_URL="https://kojipkgs.fedoraproject.org/compose/iot/${COMPOSE}/compose/IoT/${ARCH}/iso"
COMPOSE_ID=$(echo "${COMPOSE}" | cut -d- -f4)

# Set OS-specific variables
case "${ID}-${VERSION_ID}" in
    "fedora-42")
        OSTREE_REF="fedora/stable/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        IMAGE_FILENAME="Fedora-IoT-provisioner-42-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-43")
        OSTREE_REF="fedora/devel/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        IMAGE_FILENAME="Fedora-IoT-provisioner-43-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-44")
        OSTREE_REF="fedora/rawhide/${ARCH}/iot"
        OS_VARIANT="fedora-rawhide"
        IMAGE_FILENAME="Fedora-IoT-provisioner-44-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    *)
        log_error "Unsupported distro: ${ID}-${VERSION_ID}"
        exit 1
        ;;
esac

# Setup FDO server
setup_fdo_server() {
    log_info "Setting up FDO server..."
    
    sudo dnf install -y \
        fdo-admin-cli \
        fdo-rendezvous-server \
        fdo-owner-onboarding-server \
        fdo-owner-cli \
        fdo-manufacturing-server \
        python3-pip

    sudo mkdir -p /etc/fdo/keys
    for obj in diun manufacturer device-ca owner; do
        sudo fdo-admin-tool generate-key-and-cert --destination-dir /etc/fdo/keys "$obj"
    done
    
    sudo mkdir -p \
        /etc/fdo/manufacturing-server.conf.d/ \
        /etc/fdo/owner-onboarding-server.conf.d/ \
        /etc/fdo/rendezvous-server.conf.d/ \
        /etc/fdo/serviceinfo-api-server.conf.d/
    
    # Copy configuration files
    sudo cp files/fdo/manufacturing-server.yml /etc/fdo/manufacturing-server.conf.d/
    sudo cp files/fdo/owner-onboarding-server.yml /etc/fdo/owner-onboarding-server.conf.d/
    sudo cp files/fdo/rendezvous-server.yml /etc/fdo/rendezvous-server.conf.d/
    sudo cp files/fdo/serviceinfo-api-server.yml /etc/fdo/serviceinfo-api-server.conf.d/
    
    # Install yq and modify configuration
    sudo pip3 install yq
    sudo yq -iy '.service_info.diskencryption_clevis |= null' /etc/fdo/serviceinfo-api-server.conf.d/serviceinfo-api-server.yml
    
    # Start FDO services
    local fdo_services=(
        fdo-owner-onboarding-server.service
        fdo-rendezvous-server.service
        fdo-manufacturing-server.service
        fdo-serviceinfo-api-server.service
    )
    
    for service in "${fdo_services[@]}"; do
        if ! sudo systemctl start "${service}"; then
            log_error "Failed to start ${service}"
            exit 1
        fi
    done
    
    # Wait for FDO server to be running
    log_info "Waiting for FDO server to start..."
    local timeout=300
    local interval=5
    local elapsed=0
    
    while ! curl -s -X POST http://192.168.100.1:8080/ping | grep -q "pong"; do
        sleep "${interval}"
        elapsed=$((elapsed + interval))
        
        if [[ ${elapsed} -ge ${timeout} ]]; then
            log_error "FDO server timed out after ${timeout} seconds"
            exit 1
        fi
    done
    
    log_success "FDO server is running"
}

# Setup Ignition configuration
setup_ignition() {
    log_info "Setting up Ignition configuration..."
    
    local ignition_dir="/var/www/html/ignition"
    local ignition_file="${ignition_dir}/fiot.ign"
    
    sudo mkdir -p "${ignition_dir}"
    
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

# Execute steps
download_image
setup_fdo_server
setup_ignition

log_info "Starting VM installation..."
sudo cp "${IMAGE_FILENAME}" /var/lib/libvirt/images/"${IMAGE_FILENAME}"

sudo virt-install \
    --name "iot-${TEST_UUID}" \
    --memory 4096 \
    --vcpus 2 \
    --os-variant "${OS_VARIANT}" \
    --disk "path=/var/lib/libvirt/images/iot-${TEST_UUID}.qcow2,format=qcow2,size=20,bus=virtio" \
    --network "network=integration,mac=34:49:22:B0:83:30" \
    --boot uefi \
    --tpm "backend.type=emulator,backend.version=2.0,model=tpm-tis" \
    --extra-args="rd.neednet=1 coreos.inst.crypt_root=1 coreos.inst.isoroot=Fedora-${VERSION_ID}-IoT-${ARCH} coreos.inst.install_dev=/dev/vda coreos.inst.image_file=/run/media/iso/image.raw.xz coreos.inst.insecure fdo.manufacturing_server_url=http://192.168.100.1:8080 fdo.diun_pub_key_insecure=true coreos.inst.append=rd.neednet=1 coreos.inst.append=ignition.config.url=http://192.168.100.1/ignition/fiot.ign console=ttyS0" \
    --location "/var/lib/libvirt/images/${IMAGE_FILENAME},initrd=images/pxeboot/initrd.img,kernel=images/pxeboot/vmlinuz" \
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
if ! ansible-playbook -v -i "${TEMPDIR}/inventory" -e fdo_credential="true" -e ostree_ref="fedora-iot:${OSTREE_REF}" check-ostree-iot.yaml; then
    log_error "Ansible playbook check failed"
    exit 1
fi

log_success "Test completed successfully"

exit 0
