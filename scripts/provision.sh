#!/bin/bash
set -exuo pipefail

# Install packages
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo dnf install -y --nogpgcheck osbuild-composer composer-cli git curl jq expect wget ansible podman httpd qemu-img qemu-kvm virt-install libvirt-client libvirt-daemon-kvm bash-completion
sudo rpm -qa|grep osbuild

# Prepare osbuild-composer repository file
sudo mkdir -p /etc/osbuild-composer/repositories
sudo cp osbuild-composer/test/data/repositories/rhel-84.json /etc/osbuild-composer/repositories/rhel-8-beta.json

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