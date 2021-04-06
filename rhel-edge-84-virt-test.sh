#!/bin/bash
# Test script to test RHEL for edge on RHEL 8.4 virtual.
# Will prepare the env, download upstream test script and run it.
set -exuo pipefail

greenprint "Git clone upstream project osbuild/osbuild-composer"
git clone -b rhel-8.4.0 https://github.com/osbuild/osbuild-composer.git
sudo mkdir -p /usr/libexec/osbuild-composer-test
sudo cp scripts/provision.sh /usr/libexec/osbuild-composer-test/provision.sh
osbuild-composer/test/cases/ostree-ng.sh