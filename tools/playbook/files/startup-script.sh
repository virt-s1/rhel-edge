#!/bin/bash

echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers

source /etc/os-release

# All Fedora GCP images do not support auto resize root disk
if [[ "$ID" == "fedora" ]]; then
    growpart /dev/sda 5
    btrfs filesystem resize 1:+70G /
fi

# Enable CRB repo on Centos Stream
if [[ "${ID}-${VERSION_ID}" == "centos-9" ]]; then
    dnf config-manager --set-enabled crb
fi
if [[ "${ID}-${VERSION_ID}" == "centos-8" ]]; then
    dnf config-manager --set-enabled powertools
fi
