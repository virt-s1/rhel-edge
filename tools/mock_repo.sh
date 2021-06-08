#!/bin/bash
set -euox pipefail

# Get OS data.
source /etc/os-release
ARCH=$(uname -m)

# work with mock osbuild-composer repo
if [[ $# -eq 1 || $# -eq 2 ]]; then
    osbuild_composer_commit_sha=$1
    sudo tee "/etc/yum.repos.d/osbuild-composer.repo" > /dev/null << EOF
[osbuild-composer]
name=osbuild-composer ${osbuild_composer_commit_sha}
baseurl=http://osbuild-composer-repos.s3-website.us-east-2.amazonaws.com/osbuild-composer/${ID}-${VERSION_ID}/${ARCH}/${osbuild_composer_commit_sha}
enabled=1
gpgcheck=0
priority=5
EOF
fi

if [[ $# -eq 2 ]]; then
    osbuild_commit_sha=$2
    sudo tee "/etc/yum.repos.d/osbuild.repo" > /dev/null << EOF
[osbuild]
name=osbuild ${osbuild_commit_sha}
baseurl=http://osbuild-composer-repos.s3-website.us-east-2.amazonaws.com/osbuild/${ID}-${VERSION_ID}/${ARCH}/${osbuild_commit_sha}
enabled=1
gpgcheck=0
priority=10
EOF
fi

sudo dnf clean all
