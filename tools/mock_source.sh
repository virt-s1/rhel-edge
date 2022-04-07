#!/bin/bash
set -exuo pipefail

TEMPDIR=$(mktemp -d)
# Create repo folder for httpd
sudo mkdir -p /var/www/html/mock_source

# Copy all rpm files in TEMPDIR into mock_source folder
sudo cp "/tmp/rpms/*.rpm" /var/www/html/mock_source

# Install createrepo_c and httpd
sudo dnf install -y createrepo_c httpd

# Create a repo for mock source
sudo createrepo_c /var/www/html/mock_source

# Start httpd
sudo systemctl enable --now httpd.service

# Add a new source
sudo tee "$TEMPDIR/source.toml" > /dev/null << EOF
id = "source01"
name = "source01"
type = "yum-baseurl"
url = "http://192.168.100.1/mock_source"
check_gpg = false
check_ssl = false
system = false
EOF

sudo composer-cli sources add "$TEMPDIR/source.toml"
for SOURCE in $(sudo composer-cli sources list); do
    sudo composer-cli sources info "$SOURCE"
done
