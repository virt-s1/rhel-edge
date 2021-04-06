#!/bin/bash
# This file is here because upstream test scripts ostree-ng.sh will call it.
#
# The steps in this file are moved to rhel-edge-84-virt-test.sh, which is the main script to test RHEL 8.4
set -exuo pipefail

echo "===>Install packages"
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo dnf install -y --nogpgcheck osbuild-composer composer-cli git curl jq expect wget ansible podman httpd qemu-img qemu-kvm virt-install libvirt-client libvirt-daemon-kvm bash-completion
sudo rpm -qa|grep osbuild

echo "===>Prepare osbuild-composer repository file"
sudo mkdir -p /etc/osbuild-composer/repositories
sudo cp osbuild-composer/test/data/repositories/rhel-84.json /etc/osbuild-composer/repositories/rhel-8-beta.json

echo "===>Prepare RSA key files"
sudo mkdir -p /usr/share/tests/osbuild-composer/keyring
sudo cp osbuild-composer/test/data/keyring/id_rsa /usr/share/tests/osbuild-composer/keyring/
sudo chmod 600 /usr/share/tests/osbuild-composer/keyring/*

# Copy provision file to target place, which will be called by ostree-ng.sh
echo "===>Prepare provision file"
sudo mkdir -p /usr/libexec/osbuild-composer-test
sudo cp ./scripts/provision.sh /usr/libexec/osbuild-composer-test/provision.sh

echo "===>Prepare ansible playbook"
sudo mkdir -p /usr/share/tests/osbuild-composer/ansible
sudo cp osbuild-composer/test/data/ansible/check_ostree.yaml /usr/share/tests/osbuild-composer/ansible/

echo "===>Start image builder service"
sudo systemctl enable --now osbuild-composer.socket
#sudo systemctl start osbuild-composer.socket
#sudo systemctl start osbuild-composer.service