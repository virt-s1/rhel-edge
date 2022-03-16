#!/bin/bash
set -exuo pipefail

# Create repo folder for httpd
sudo mkdir -p /var/www/html/mock_source

# Copy all rpm files in repo root folder into mock_source folder
sudo cp ./*.rpm /var/www/html/mock_source

# Install createrepo_c and httpd
sudo dnf install -y createrepo_c httpd

# Create a repo for mock source
sudo createrepo_c /var/www/html/mock_source

# Start httpd
sudo systemctl enable --now httpd.service
