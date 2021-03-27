#!/bin/bash
#=================================================================================
# Defines global variables that will be used in main test script
#
# @Author yih@redhat.com
# @Date: 3/26/2021
#=================================================================================

#Define image types
IMAGE_TYPE_COMMIT=rhel-edge-commit
IMAGE_TYPE_CONTAINER=rhel-edge-container
IMAGE_TYPE_INSTALLER=rhel-edge-installer

#Define http path
HTTPD_PATH=/var/www/html

#Define edge repo url
REPO_URL="http://192.168.100.1/repo/"

#Define SSH vars
GUEST_ADDRESS=192.168.100.50
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key

#Define boot location
RHEL_84_VARIANT="rhel8-unknown"
BOOT_LOCATION="http://download.devel.redhat.com/nightly/rhel-8/RHEL-8/latest-RHEL-8.4.0/compose/BaseOS/x86_64/os/"