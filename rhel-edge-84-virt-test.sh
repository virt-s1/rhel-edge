#!/bin/bash
# Test script to test RHEL for edge on RHEL 8.4 virtual.
# Will prepare the env, download upstream test script and run it.

set -uo pipefail
source /etc/os-release

function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Initialize repo
greenprint "Configure yum repository"
sudo tee /etc/yum.repos.d/rhel84.repo << EOF
[RHEL-8-NIGHTLY-BaseOS]
name=baseos
baseurl=http://download-node-02.eng.bos.redhat.com/rhel-8/development/RHEL-8/latest-RHEL-8.4.0/compose/BaseOS/x86_64/os/
enabled=1
gpgcheck=0
[RHEL-8-NIGHTLY-AppStream]
name=appstream
baseurl=http://download-node-02.eng.bos.redhat.com/rhel-8/development/RHEL-8/latest-RHEL-8.4.0/compose/AppStream/x86_64/os/
enabled=1
gpgcheck=0
EOF

greenprint "Install packages: git wget ansible httpd osbuild-composer composer-cli"
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo dnf install -y --nogpgcheck osbuild-composer composer-cli git curl jq expect wget ansible podman httpd qemu-img qemu-kvm virt-install libvirt-client libvirt-daemon-kvm bash-completion
sudo rpm -qa|grep osbuild

greenprint "Start image builder service"
sudo systemctl enable --now osbuild-composer.socket
sudo systemctl start osbuild-composer.socket
sudo systemctl start osbuild-composer.service

greenprint "Git clone upstream project osbuild/osbuild-composer"
sudo git clone https://github.com/osbuild/osbuild-composer.git
# shellcheck disable=SC2164
cd osbuild-composer/
sudo git checkout rhel-8.4.0
# shellcheck disable=SC2103
cd ..

greenprint "Prepare osbuild-composer repository file"
if [ ! -d /etc/osbuild-composer/repositories ]; then
    sudo mkdir -p /etc/osbuild-composer/repositories
fi
sudo cp osbuild-composer/test/data/repositories/rhel-84.json /etc/osbuild-composer/repositories/rhel-8-beta.json

greenprint "Prepare RSA key files"
if [ ! -d /usr/share/tests/osbuild-composer/keyring ]; then
    sudo mkdir -p /usr/share/tests/osbuild-composer/keyring
fi
sudo cp osbuild-composer/test/data/keyring/id_rsa /usr/share/tests/osbuild-composer/keyring/
sudo chmod 600 /usr/share/tests/osbuild-composer/keyring/*

# Copy provision file to target place, which will be called by ostree-ng.sh
greenprint "Prepare provision file"
if [ ! -d /usr/libexec/osbuild-composer-test ]; then
    sudo mkdir -p /usr/libexec/osbuild-composer-test
    sudo cp ./scripts/provision.sh /usr/libexec/osbuild-composer-test/provision.sh
fi
sudo cp ./scripts/provision.sh /usr/libexec/osbuild-composer-test/provision.sh

greenprint "Prepare ansible playbook"
if [ ! -d /usr/share/tests/osbuild-composer/ansible ]; then
    sudo mkdir -p /usr/share/tests/osbuild-composer/ansible
fi
sudo cp osbuild-composer/test/data/ansible/check_ostree.yaml /usr/share/tests/osbuild-composer/ansible/

sleep 10
sudo systemctl start osbuild-composer.service

WORKSPACE=$(pwd)
export WORKSPACE

./osbuild-composer/test/cases/ostree-ng.sh