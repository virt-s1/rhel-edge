#!/bin/bash
set -euox pipefail

# Provision the software under test.
./setup.sh

# Get OS data.
source /etc/os-release
ARCH=$(uname -m)

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="ostree-commit-${TEST_UUID}"
PROD_REPO_URL=http://192.168.100.1/repo
PROD_REPO=/var/www/html/repo
GUEST_ADDRESS=192.168.100.50
EDGE_USER_PASSWORD=foobar
OS_NAME="rhel-edge"

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
KS_FILE=${TEMPDIR}/ks.cfg
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)

# Prepare osbuild-composer repository file
sudo mkdir -p /etc/osbuild-composer/repositories

# RHEL 8.8 and CS8 is still RO for /sysroot on raw image and simplified installer
# The RO setting on RHEL 8.8 and CS8 is not configured by ostree, but osbuild-composer
# by PR https://github.com/osbuild/osbuild-composer/pull/3178
case "${ID}-${VERSION_ID}" in
    "rhel-9.4")
        IMAGE_TYPE=edge-commit
        OSTREE_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9-unknown"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/nightly/updates/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/x86_64/os/"
        ;;
    "rhel-9.5")
        IMAGE_TYPE=edge-commit
        OSTREE_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9-unknown"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.5.0/compose/BaseOS/x86_64/os/"
        ;;
    "rhel-9.6")
        IMAGE_TYPE=edge-commit
        OSTREE_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9-unknown"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.6.0/compose/BaseOS/x86_64/os/"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Pulp setup
PULP_CONFIG_FILE="$(pwd)/pulp.toml"
PULP_SERVER="http://192.168.100.1:9090"
PULP_USERNAME="admin"
PULP_PASSWORD="foobar"
PULP_REPO="commit"
PULP_BASEPATH="commit"

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-raw-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-raw-${COMPOSE_ID}.json

    # Download the metadata.
    sudo composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    sudo tar -xf "$TARBALL" -C "${TEMPDIR}"
    sudo rm -f "$TARBALL"

    # Move the JSON file into place.
    sudo cat "${TEMPDIR}"/"${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
}

# Build ostree image.
build_image() {
    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!
    # Stop watching the worker journal when exiting.
    trap 'sudo pkill -P ${WORKER_JOURNAL_PID}' EXIT

    # Start the compose.
    greenprint "🚀 Starting compose"
    blueprint_name=$1
    image_type=$2
    # for pulp first build
    if [ $# -eq 4 ]; then
        image_key=$3
        pulp_config=$4
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" "$image_type" "$image_key" "$pulp_config" | tee "$COMPOSE_START"
    # for pulp upgrade build
    else
        image_key=$3
        pulp_config=$4
        repo_url=$5
        parent_ref=$6
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" --parent "$parent_ref" --url "$repo_url" "$blueprint_name" "$image_type" "$image_key" "$pulp_config" | tee "$COMPOSE_START"
    fi
    COMPOSE_ID=$(jq -r '.[0].body.build_id' "$COMPOSE_START")

    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null
        COMPOSE_STATUS=$(jq -r '.[0].body.queue_status' "$COMPOSE_INFO")

        # Is the compose finished?
        if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
            break
        fi

        # Wait 30 seconds and try again.
        sleep 5
    done

    # Capture the compose logs from osbuild.
    greenprint "💬 Getting compose log and metadata"
    get_compose_log "$COMPOSE_ID"
    get_compose_metadata "$COMPOSE_ID"

    # Kill the journal monitor immediately and remove the trap
    sudo pkill -P ${WORKER_JOURNAL_PID}
    trap - EXIT

    # Did the compose finish with success?
    if [[ $COMPOSE_STATUS != FINISHED ]]; then
        redprint "Something went wrong with the compose. 😢"
        exit 1
    fi
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"
    sudo virsh destroy "${IMAGE_KEY}"
    if [[ $ARCH == aarch64 ]]; then
        sudo virsh undefine "${IMAGE_KEY}" --nvram
    else
        sudo virsh undefine "${IMAGE_KEY}"
    fi
    # Remove qcow2 file.
    sudo rm -f "$LIBVIRT_IMAGE_PATH"
    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"
    # Remove pulp config file
    sudo rm -rf "$PULP_CONFIG_FILE"
    # Remove pulp directories
    sudo rm -rf settings pulp_storage pgsql containers
    # Stop httpd
    sudo systemctl disable httpd --now
}

# Test result checking
check_result () {
    greenprint "🎏 Checking for test result"
    if [[ $RESULTS == 1 ]]; then
        greenprint "💚 Success"
    else
        greenprint "❌ Failed"
        clean_up
        exit 1
    fi
}

##################################################
##
## Upload ostree commit to pulp test
##
##################################################
# Setup pulp server
greenprint "📄 Setup pulp server with one container"
mkdir -p settings pulp_storage pgsql containers
echo "CONTENT_ORIGIN='http://192.168.100.1:8080'
ANSIBLE_API_HOSTNAME='http://192.168.100.1:8080'
ANSIBLE_CONTENT_HOSTNAME='http://192.168.100.1:8080/pulp/content'
CACHE_ENABLED=True" >> settings/settings.py
sudo podman run --detach \
            --publish 9090:80 \
            --name pulp \
            --volume "$(pwd)/settings":/etc/pulp:Z \
            --volume "$(pwd)/pulp_storage":/var/lib/pulp:Z \
            --volume "$(pwd)/pgsql":/var/lib/pgsql:Z \
            --volume "$(pwd)/containers":/var/lib/containers:Z \
            --device /dev/fuse \
            quay.io/pulp/pulp:nightly

# Wait until pulp service is fully functional
sleep 120

# Rotate pulp admin password
greenprint "📄 Rotate pulp admin password"
/usr/bin/expect <<-EOF
spawn sudo podman exec -it pulp bash -c "pulpcore-manager reset-admin-password"
expect {
"*password" { send "${PULP_PASSWORD}\r"; exp_continue }
"*again" { send "${PULP_PASSWORD}\r" }
}
expect eof
EOF

# Write a pulp config file.
greenprint "📄 Prepare pulp config file"
tee "$PULP_CONFIG_FILE" > /dev/null << EOF
provider = "pulp.ostree"

[settings]
server_address = "${PULP_SERVER}"
repository = "${PULP_REPO}"
basepath = "${PULP_BASEPATH}"
username = "${PULP_USERNAME}"
password = "${PULP_PASSWORD}"
EOF

greenprint "📄 pulp config file:"
cat "$PULP_CONFIG_FILE"

# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "ostree"
description = "A base ostree image"
version = "0.0.1"
modules = []
groups = []

[[packages]]
name = "python3"
version = "*"

[[packages]]
name = "sssd"
version = "*"

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "${SSH_KEY_PUB}"
home = "/home/admin/"
groups = ["wheel"]
EOF

greenprint "📄 ostree blueprint"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve ostree

# Build commit image
# The parameter value "test" has no effect for this command,
# see https://github.com/osbuild/guides/pull/144/files#diff-29259e84e167d353f6de0e135615d0f11b083af6865ddfd34e4e7014b4d53600R28
build_image ostree "$IMAGE_TYPE" test "$PULP_CONFIG_FILE"

# Start httpd to serve ostree repo.
greenprint "🚀 Starting httpd daemon"
sudo systemctl start httpd

# Pull commit from pulp to local repo
greenprint "Pull commit from pulp to production repo"
sudo rm -fr "$PROD_REPO"
sudo mkdir -p "$PROD_REPO"
sudo ostree --repo="$PROD_REPO" init --mode=archive
sudo ostree --repo="$PROD_REPO" remote add --no-gpg-verify edge-pulp http://localhost:9090/pulp/content/${PULP_REPO}/
sudo ostree --repo="$PROD_REPO" pull --mirror edge-pulp "$OSTREE_REF"

# Clean compose and blueprints.
greenprint "Clean up osbuild-composer"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete ostree > /dev/null

# Ensure SELinux is happy with our new images.
greenprint "👿 Running restorecon on image directory"
sudo restorecon -Rv /var/lib/libvirt/images/

# Ensure SELinux is happy with all objects files.
greenprint "👿 Running restorecon on web server root folder"
sudo restorecon -Rv "${PROD_REPO}" > /dev/null

# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt install"
LIBVIRT_IMAGE_PATH=/var/lib/libvirt/images/${IMAGE_KEY}-pulp.qcow2
sudo qemu-img create -f qcow2 "${LIBVIRT_IMAGE_PATH}" 20G

# Write kickstart file for ostree image installation.
greenprint "Generate kickstart file"
tee "$KS_FILE" > /dev/null << STOPHERE
text
lang en_US.UTF-8
keyboard us
timezone --utc Etc/UTC

selinux --enforcing
rootpw --lock --iscrypted locked
bootloader --timeout=1 --append="net.ifnames=0 modprobe.blacklist=vc4"

network --bootproto=dhcp --device=link --activate --onboot=on

zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
ostreesetup --nogpg --osname=${OS_NAME} --remote=${OS_NAME} --url=${PROD_REPO_URL} --ref=${OSTREE_REF}
poweroff

%post --log=/var/log/anaconda/post-install.log --erroronfail

# no sudo password for SSH user
echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers

# Remove any persistent NIC rules generated by udev
rm -vf /etc/udev/rules.d/*persistent-net*.rules
# And ensure that we will do DHCP on eth0 on startup
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
DEVICE="eth0"
BOOTPROTO="dhcp"
ONBOOT="yes"
TYPE="Ethernet"
PERSISTENT_DHCLIENT="yes"
EOF

echo "Packages within this iot or edge image:"
echo "-----------------------------------------------------------------------"
rpm -qa | sort
echo "-----------------------------------------------------------------------"
# Note that running rpm recreates the rpm db files which aren't needed/wanted
rm -f /var/lib/rpm/__db*

echo "Zeroing out empty space."
# This forces the filesystem to reclaim space from deleted files
dd bs=1M if=/dev/zero of=/var/tmp/zeros || :
rm -f /var/tmp/zeros
echo "(Don't worry -- that out-of-space error was expected.)"

%end
STOPHERE

# Get the boot.iso from BOOT_LOCATION
curl -O "$BOOT_LOCATION"images/boot.iso
sudo mv boot.iso /var/lib/libvirt/images
LOCAL_BOOT_LOCATION="/var/lib/libvirt/images/boot.iso"

# Install ostree image via anaconda.
greenprint "Install ostree image via anaconda"
sudo virt-install  --initrd-inject="${KS_FILE}" \
                   --extra-args="inst.ks=file:/ks.cfg console=ttyS0,115200" \
                   --name="${IMAGE_KEY}"\
                   --disk path="${LIBVIRT_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-variant ${OS_VARIANT} \
                   --location ${LOCAL_BOOT_LOCATION} \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${IMAGE_KEY}"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Reboot one more time to make /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'
# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

check_result

greenprint "🕹 Get ostree install commit value"
INSTALL_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

# Add instance IP address into /etc/ansible/hosts
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes
ansible_become_method=sudo
ansible_become_pass=${EDGE_USER_PASSWORD}
EOF

# Test IoT/Edge OS
sudo podman run --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory \
    -e os_name="${OS_NAME}" \
    -e ostree_ref="${OS_NAME}:${OSTREE_REF}" \
    -e ostree_commit="${INSTALL_HASH}" \
    -e sysroot_ro="true" \
    check-ostree.yaml || RESULTS=0 
check_result

clean_up

exit 0
