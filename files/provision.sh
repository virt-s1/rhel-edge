#!/bin/bash
set -exuo pipefail

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
echo -e "\033[0m"

# Get OS data.
source /etc/os-release

# Install packages
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo dnf install -y --nogpgcheck osbuild-composer composer-cli git curl jq expect wget ansible podman httpd qemu-img qemu-kvm virt-install libvirt-client libvirt-daemon-kvm bash-completion
sudo rpm -qa | grep -i osbuild

# Prepare osbuild-composer repository file
sudo mkdir -p /etc/osbuild-composer/repositories
case "${ID}-${VERSION_ID}" in
    "rhel-8.3")
        sudo cp files/rhel-8-3-1.json /etc/osbuild-composer/repositories/rhel-8.json;;
    "rhel-8.4")
        sudo cp files/rhel-8-4-0.json /etc/osbuild-composer/repositories/rhel-8-beta.json
        sudo ln -sf /etc/osbuild-composer/repositories/rhel-8-beta.json /etc/osbuild-composer/repositories/rhel-8.json;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Prepare RSA key files(this step is not needed in jenkins run env, keep it here for local test.)
sudo mkdir -p /usr/share/tests/osbuild-composer/keyring
sudo cp osbuild-composer/test/data/keyring/id_rsa /usr/share/tests/osbuild-composer/keyring/
sudo chmod 600 /usr/share/tests/osbuild-composer/keyring/*

# Prepare ansible playbook
sudo mkdir -p /usr/share/tests/osbuild-composer/ansible
sudo cp osbuild-composer/test/data/ansible/check_ostree.yaml /usr/share/tests/osbuild-composer/ansible/

# Start image builder service
sudo systemctl enable --now osbuild-composer.socket

# Basic verification
sudo composer-cli status show
sudo composer-cli sources list
for SOURCE in $(sudo composer-cli sources list); do
    sudo composer-cli sources info "$SOURCE"
done
