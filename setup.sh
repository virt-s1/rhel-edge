#!/bin/bash
set -euox pipefail

# Dumps details about the instance running the CI job.
CPUS=$(nproc)
MEM=$(free -m | grep -oP '\d+' | head -n 1)
DISK=$(df --output=size -h / | sed '1d;s/[^0-9]//g')
HOSTNAME=$(uname -n)
USER=$(whoami)
ARCH=$(uname -m)
KERNEL=$(uname -r)

echo -e "\033[0;36m"
cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
     Hostname: ${HOSTNAME}
         User: ${USER}
         CPUs: ${CPUS}
          RAM: ${MEM} MB
         DISK: ${DISK} GB
         ARCH: ${ARCH}
       KERNEL: ${KERNEL}
------------------------------------------------------------------------------
EOF
echo "CPU info"
lscpu
echo -e "\033[0m"

# Get OS data.
source /etc/os-release

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# set locale to en_US.UTF-8
sudo dnf install -y glibc-langpack-en
sudo localectl set-locale LANG=en_US.UTF-8

# Install openshift client
curl https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz | sudo tar -xz -C /usr/local/bin/
# Install ansible
sudo dnf install -y --nogpgcheck ansible-core
# To support stdout_callback = yaml
sudo ansible-galaxy collection install community.general

# Install required packages
greenprint "Install required packages"
sudo dnf install -y --nogpgcheck httpd osbuild osbuild-composer composer-cli podman skopeo wget firewalld lorax xorriso curl jq expect qemu-img qemu-kvm libvirt-client libvirt-daemon-kvm virt-install
if [[ $ID == "centos" && $VERSION_ID == "8" ]]; then
    # Workaround for https://bugzilla.redhat.com/show_bug.cgi?id=2065292
    # Remove when podman-4.0.2-2.el8 is in Centos 8 repositories
    greenprint "Updating libseccomp on Centos 8"
    sudo dnf upgrade -y libseccomp
fi
sudo rpm -qa | grep -i osbuild

# Customize repository
sudo mkdir -p /etc/osbuild-composer/repositories

case "${ID}-${VERSION_ID}" in
    "rhel-8.6")
        sudo cp files/rhel-8-6-0.json /etc/osbuild-composer/repositories/rhel-86.json;;
    "rhel-8.7")
        sudo cp files/rhel-8-7-0.json /etc/osbuild-composer/repositories/rhel-87.json;;
    "rhel-9.0")
        sudo cp files/rhel-8-6-0-sha512.json /etc/osbuild-composer/repositories/rhel-86.json
        sudo cp files/rhel-9-0-0.json /etc/osbuild-composer/repositories/rhel-90.json;;
    "rhel-9.1")
        # Wordaround bug https://bugzilla.redhat.com/show_bug.cgi?id=2116221
        sudo dnf install -y http://download.eng.bos.redhat.com/brewroot/vol/rhel-9/packages/aardvark-dns/1.1.0/2.el9/x86_64/aardvark-dns-1.1.0-2.el9.x86_64.rpm
        sudo cp files/rhel-8-7-0-sha512.json /etc/osbuild-composer/repositories/rhel-87.json
        sudo cp files/rhel-9-1-0.json /etc/osbuild-composer/repositories/rhel-91.json;;
    "centos-8")
        sudo cp files/centos-stream-8.json /etc/osbuild-composer/repositories/centos-8.json;;
    "centos-9")
        # Wordaround bug https://bugzilla.redhat.com/show_bug.cgi?id=2116221
        sudo dnf install -y https://kojihub.stream.centos.org/kojifiles/packages/aardvark-dns/1.1.0/2.el9/x86_64/aardvark-dns-1.1.0-2.el9.x86_64.rpm
        sudo cp files/centos-stream-8.json /etc/osbuild-composer/repositories/centos-8.json
        sudo cp files/centos-stream-9.json /etc/osbuild-composer/repositories/centos-9.json;;
    "fedora-36")
        ;;
    "fedora-37")
        ;;
    "fedora-38")
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Check ostree_key permissions
KEY_PERMISSION_PRE=$(stat -L -c "%a %G %U" key/ostree_key | grep -oP '\d+' | head -n 1)
echo -e "${KEY_PERMISSION_PRE}"
if [[ "${KEY_PERMISSION_PRE}" != "600" ]]; then
   greenprint "💡 File permissions too open...Changing to 600"
   chmod 600 ./key/ostree_key
fi

# Start httpd server as prod ostree repo
greenprint "Start httpd service"
sudo systemctl enable --now httpd.service

# Start osbuild-composer.socket
greenprint "Start osbuild-composer.socket"
sudo systemctl enable --now osbuild-composer.socket

# Start firewalld
greenprint "Start firewalld"
sudo systemctl enable --now firewalld

# workaround for bug https://bugzilla.redhat.com/show_bug.cgi?id=2057769
if [[ "$VERSION_ID" == "9.0" || "$VERSION_ID" == "9.1" || "$VERSION_ID" == "9" ]]; then
    if [[ -f "/usr/share/qemu/firmware/50-edk2-ovmf-amdsev.json" ]]; then
        jq '.mapping += {"nvram-template": {"filename": "/usr/share/edk2/ovmf/OVMF_VARS.fd","format": "raw"}}' /usr/share/qemu/firmware/50-edk2-ovmf-amdsev.json | sudo tee /tmp/50-edk2-ovmf-amdsev.json
        sudo mv /tmp/50-edk2-ovmf-amdsev.json /usr/share/qemu/firmware/50-edk2-ovmf-amdsev.json
    fi
fi

# Start libvirtd and test it.
greenprint "🚀 Starting libvirt daemon"
sudo systemctl start libvirtd
sudo virsh list --all > /dev/null

# Set a customized dnsmasq configuration for libvirt so we always get the
# same address on bootup.
greenprint "💡 Setup libvirt network"
sudo tee /tmp/integration.xml > /dev/null << EOF
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
if ! sudo virsh net-info integration > /dev/null 2>&1; then
    sudo virsh net-define /tmp/integration.xml
fi
if [[ $(sudo virsh net-info integration | grep 'Active' | awk '{print $2}') == 'no' ]]; then
    sudo virsh net-start integration
fi

# Allow anyone in the wheel group to talk to libvirt.
greenprint "🚪 Allowing users in wheel group to talk to libvirt"
sudo tee /etc/polkit-1/rules.d/50-libvirt.rules > /dev/null << EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("adm")) {
            return polkit.Result.YES;
    }
});
EOF

# Basic weldr API status checking
sudo composer-cli status show

# RHEL for Edge package test
if [ -e packages/package_ci_trigger ]; then
    source packages/package_ci_trigger

    # Get package rpm download URL
    IFS=',' read -r -a package_rpms <<< "$PACKAGE_RPM_LIST"

    # Download package rpms to /var/www/html/packages
    sudo mkdir -p /var/www/html/packages
    for i in "${package_rpms[@]}"; do
        if [[ ${i} != *"debug"* && ${i} != *"devel"* ]]; then
            sudo wget -q "http://download.eng.bos.redhat.com/brewroot/work/${i}" -P /var/www/html/packages
        fi
    done

    # Make all packages as a repo
    sudo dnf install -y createrepo_c
    sudo createrepo_c /var/www/html/packages

    # Create source configuration file
    sudo tee "/tmp/source.toml" > /dev/null << EOF
id = "packages"
name = "packages"
type = "yum-baseurl"
url = "http://192.168.100.1/packages"
check_gpg = false
check_ssl = false
system = false
EOF

    sudo composer-cli sources add "/tmp/source.toml"
fi

# Source checking
sudo composer-cli sources list
for SOURCE in $(sudo composer-cli sources list); do
    sudo composer-cli sources info "$SOURCE"
done
