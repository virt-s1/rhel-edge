#!/usr/bin/env bash
set -euo pipefail

# Color definitions
COLOR_CYAN='\033[0;36m'
COLOR_GREEN='\033[1;32m'
COLOR_RESET='\033[0m'

# Logging functions
log_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

# Function to display system specifications
display_system_specs() {
    local cpus mem disk hostname user arch kernel
    
    cpus=$(nproc)
    mem=$(free -m | awk '/^Mem:/ {print $2}')
    disk=$(df -h / | awk 'NR==2 {print $2}' | sed 's/G//')
    hostname=$(uname -n)
    user=$(whoami)
    arch=$(uname -m)
    kernel=$(uname -r)
    
    echo -e "${COLOR_CYAN}"
    cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
     Hostname: ${hostname}
         User: ${user}
         CPUs: ${cpus}
          RAM: ${mem} MB
         DISK: ${disk} GB
         ARCH: ${arch}
       KERNEL: ${kernel}
------------------------------------------------------------------------------
EOF
    
    log_info "CPU details:"
    lscpu
    echo -e "${COLOR_RESET}"
}

# Function to install required packages
install_packages() {
    local packages=(
        glibc-langpack-en
        httpd
        podman
        skopeo
        wget
        firewalld
        lorax
        xorriso
        curl
        jq
        expect
        qemu-img
        qemu-kvm
        libvirt-client
        libvirt-daemon-kvm
        libvirt-daemon
        virt-install
        rpmdevtools
        createrepo_c
        lsof
        ansible-core
    )
    
    log_info "Installing required packages"
    sudo dnf install -y --nogpgcheck "${packages[@]}"
    sudo ansible-galaxy collection install community.general
    
    # Set locale to en_US.UTF-8
    sudo localectl set-locale LANG=en_US.UTF-8
}

# Function to check and fix key permissions
check_key_permissions() {
    local key_path="key/ostree_key"
    
    if [[ -f "${key_path}" ]]; then
        local key_perms
        key_perms=$(stat -L -c "%a" "${key_path}")
        
        if [[ "${key_perms}" != "600" ]]; then
            log_info "File permissions too open (${key_perms}), changing to 600"
            chmod 600 "${key_path}"
        fi
    else
        log_info "Key file not found: ${key_path}"
    fi
}

# Function to configure services
configure_services() {
    log_info "Configuring services"
    
    # Enable and start services
    sudo systemctl enable --now httpd.service
    sudo systemctl enable --now firewalld
    
    # Configure libvirt permissions
    log_info "Configuring libvirt permissions"
    sudo tee /etc/polkit-1/rules.d/50-libvirt.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("adm")) {
            return polkit.Result.YES;
    }
});
EOF
    
    # Start libvirtd
    log_info "Starting libvirt daemon"
    sudo systemctl start libvirtd
    
    # Verify libvirt is working
    if ! sudo virsh list --all > /dev/null; then
        echo "Failed to connect to libvirt" >&2
        return 1
    fi
}

# Function to setup libvirt network
setup_libvirt_network() {
    local network_xml="/tmp/integration.xml"
    
    log_info "Setting up libvirt network"
    
    # Create network configuration
    sudo tee "${network_xml}" > /dev/null << 'EOF'
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>integration</name>
  <uuid>1c8fe98c-b53a-4ca4-bbdb-deb0f26b3579</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='integration' zone='trusted' stp='on' delay='0'/>
  <mac address='52:54:00:36:46:ef'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.2' end='192.168.100.254'/>
      <host mac='34:49:22:B0:83:30' name='vm-1' ip='192.168.100.50'/>
      <host mac='34:49:22:B0:83:31' name='vm-2' ip='192.168.100.51'/>
      <host mac='34:49:22:B0:83:32' name='vm-3' ip='192.168.100.52'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='dhcp-vendorclass=set:efi-http,HTTPClient:Arch:00016'/>
    <dnsmasq:option value='dhcp-option-force=tag:efi-http,60,HTTPClient'/>
    <dnsmasq:option value='dhcp-boot=tag:efi-http,&quot;http://192.168.100.1/httpboot/EFI/BOOT/BOOTX64.EFI&quot;'/>
  </dnsmasq:options>
</network>
EOF
    
    # Define network if it doesn't exist
    if ! sudo virsh net-info integration > /dev/null 2>&1; then
        sudo virsh net-define "${network_xml}"
    fi
    
    # Start network if not active
    if [[ $(sudo virsh net-info integration | awk '/Active/ {print $2}') == "no" ]]; then
        sudo virsh net-start integration
    fi
}

# Function to check and free port 8081 if needed
check_port_8081() {
    log_info "Checking port 8081 availability"
    
    if lsof -Pi :8081 -sTCP:LISTEN -t >/dev/null; then
        log_info "Port 8081 is in use, attempting to free it"
        sudo fuser -k 8081/tcp || true
        sleep 2
    fi
}


log_info "Starting CI environment setup"

# Display system specifications
display_system_specs

# Get OS data
source /etc/os-release
log_info "Detected OS: ${ID} ${VERSION_ID}"

# Install required packages
install_packages

# Check and fix key permissions
check_key_permissions

# Configure services
configure_services

# Setup libvirt network
setup_libvirt_network

# Check port 8081
check_port_8081

log_success "CI environment setup completed successfully"
