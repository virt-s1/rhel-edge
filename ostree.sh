#!/bin/bash
set -exuo pipefail

# Dumps details about the instance running the CI job.

CPUS=$(nproc)
MEM=$(free -m | grep -oP '\d+' | head -n 1)
DISK=$(df --output=size -h / | sed '1d;s/[^0-9]//g')
HOSTNAME=$(uname -n)
USER=$(whoami)
ARCH=$(uname -m)
KERNEL=$(uname -r)

echo -e "\033[0;36m"
cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
     Hostname: ${HOSTNAME}
         User: ${USER}
         CPUs: ${CPUS}
          RAM: ${MEM} MB
         DISK: ${DISK} GB
         ARCH: ${ARCH}
       KERNEL: ${KERNEL}
------------------------------------------------------------------------------
EOF
echo -e "\033[0m"

# Get OS data.
source /etc/os-release

# Prepare osbuild-composer repository file
sudo mkdir -p /etc/osbuild-composer/repositories

# Set os-variant and boot location used by virt-install.
case "${ID}-${VERSION_ID}" in
    "fedora-33")
        IMAGE_TYPE=fedora-iot-commit
        OSTREE_REF="fedora/33/${ARCH}/iot"
        OS_VARIANT="fedora33"
        USER_IN_COMMIT="false"
        BOOT_LOCATION="https://mirrors.rit.edu/fedora/fedora/linux/releases/33/Everything/x86_64/os/"
        CUT_DIRS=8
        sudo cp files/fedora-33.json /etc/osbuild-composer/repositories/fedora-33.json;;
    "rhel-8.3")
        IMAGE_TYPE=rhel-edge-commit
        OSTREE_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        USER_IN_COMMIT="false"
        sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
        sudo dnf install -y ansible
        BOOT_LOCATION="http://download-node-02.eng.bos.redhat.com/rhel-8/rel-eng/updates/RHEL-8/latest-RHEL-8.3.1/compose/BaseOS/x86_64/os/"
        CUT_DIRS=9
        sudo cp files/rhel-8-3-1.json /etc/osbuild-composer/repositories/rhel-8.json;;
    "rhel-8.4")
        IMAGE_TYPE=rhel-edge-commit
        OSTREE_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        USER_IN_COMMIT="false"
        sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
        sudo dnf install -y ansible
        BOOT_LOCATION="http://download-node-02.eng.bos.redhat.com/rhel-8/rel-eng/RHEL-8/latest-RHEL-8.4.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=8
        sudo cp files/rhel-8-4-0.json /etc/osbuild-composer/repositories/rhel-8-beta.json
        sudo ln -sf /etc/osbuild-composer/repositories/rhel-8-beta.json /etc/osbuild-composer/repositories/rhel-8.json;;
    "rhel-8.5")
        IMAGE_TYPE=edge-commit
        OSTREE_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        USER_IN_COMMIT="true"
        sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
        sudo dnf install -y ansible
        BOOT_LOCATION="http://download-node-02.eng.bos.redhat.com/rhel-8/rel-eng/RHEL-8/latest-RHEL-8.5.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=8
        sudo cp files/rhel-8-5-0.json /etc/osbuild-composer/repositories/rhel-85.json;;
    "rhel-8.6")
        IMAGE_TYPE=edge-commit
        OSTREE_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        USER_IN_COMMIT="true"
        sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
        sudo dnf install -y ansible
        BOOT_LOCATION="http://download-node-02.eng.bos.redhat.com/rhel-8/nightly/RHEL-8/latest-RHEL-8.6.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=8
        sudo cp files/rhel-8-6-0.json /etc/osbuild-composer/repositories/rhel-86.json;;
    "rhel-9.0")
        IMAGE_TYPE=edge-commit
        OSTREE_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9.0"
        USER_IN_COMMIT="false"
        BOOT_LOCATION="http://download-node-02.eng.bos.redhat.com/rhel-9/nightly/RHEL-9/latest-RHEL-9.0.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=8
        # Install ansible
        sudo dnf install -y --nogpgcheck ansible-core python-jmespath
        # To support stdout_callback = yaml
        sudo ansible-galaxy collection install community.general
        sudo cp files/rhel-9-0-0.json /etc/osbuild-composer/repositories/rhel-90.json;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Install packages
sudo dnf install -y --nogpgcheck osbuild-composer composer-cli podman httpd wget firewalld
sudo rpm -qa | grep -i osbuild

# Start image builder service
sudo systemctl enable --now osbuild-composer.socket

# Start firewalld
sudo systemctl enable --now firewalld

# Basic verification
sudo composer-cli status show
sudo composer-cli sources list
for SOURCE in $(sudo composer-cli sources list); do
    sudo composer-cli sources info "$SOURCE"
done

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Start libvirtd and test it.
greenprint "🚀 Starting libvirt daemon"
sudo systemctl start libvirtd
sudo virsh list --all > /dev/null

# Set a customized dnsmasq configuration for libvirt so we always get the
# same address on bootup.
sudo tee /tmp/integration.xml > /dev/null << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>integration</name>
  <uuid>1c8fe98c-b53a-4ca4-bbdb-deb0f26b3579</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='integration' zone='trusted' stp='on' delay='0'/>
  <mac address='52:54:00:36:46:ef'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.2' end='192.168.100.254'/>
      <host mac='34:49:22:B0:83:30' name='vm' ip='192.168.100.50'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='dhcp-vendorclass=set:efi-http,HTTPClient:Arch:00016'/>
    <dnsmasq:option value='dhcp-option-force=tag:efi-http,60,HTTPClient'/>
    <dnsmasq:option value='dhcp-boot=tag:efi-http,&quot;http://192.168.100.1/httpboot/EFI/BOOT/BOOTX64.EFI&quot;'/>
  </dnsmasq:options>
</network>
EOF
if sudo virsh net-info integration > /dev/null 2>&1; then
    sudo virsh net-destroy integration
    sudo virsh net-undefine integration
fi

sudo virsh net-define /tmp/integration.xml
sudo virsh net-start integration

# Allow anyone in the wheel group to talk to libvirt.
greenprint "🚪 Allowing users in wheel group to talk to libvirt"
WHEEL_GROUP=wheel
if [[ $ID == rhel ]]; then
    WHEEL_GROUP=adm
fi
sudo tee /etc/polkit-1/rules.d/50-libvirt.rules > /dev/null << EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("${WHEEL_GROUP}")) {
            return polkit.Result.YES;
    }
});
EOF

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="osbuild-composer-ostree-test-${TEST_UUID}"
GUEST_ADDRESS=192.168.100.50
SSH_USER="admin"

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
HTTPD_PATH="/var/www/html"
KS_FILE=${HTTPD_PATH}/ks.cfg
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json
GRUB_CFG=${HTTPD_PATH}/httpboot/EFI/BOOT/grub.cfg

# Download HTTP boot required files
greenprint "📥 Download HTTP boot required files"
sudo rm -rf "${HTTPD_PATH}/httpboot"
sudo mkdir -p "${HTTPD_PATH}/httpboot"
REQUIRED_FOLDERS=( "EFI" "images" "isolinux" )
for i in "${REQUIRED_FOLDERS[@]}"
do
    sudo wget --inet4-only -r --no-parent -e robots=off -nH --cut-dirs="$CUT_DIRS" --reject "index.html*" --reject "boot.iso" "${BOOT_LOCATION}${i}/" -P "${HTTPD_PATH}/httpboot/"
done

# Update grub.cfg to work with HTTP boot
greenprint "📝 Update grub.cfg to work with HTTP boot"
sudo tee -a "${GRUB_CFG}" > /dev/null << EOF
menuentry 'Install Red Hat Enterprise Linux for Edge 8.4' --class fedora --class gnu-linux --class gnu --class os {
        linuxefi /httpboot/images/pxeboot/vmlinuz inst.stage2=http://192.168.100.1/httpboot inst.ks=http://192.168.100.1/ks.cfg inst.text console=ttyS0,115200
        initrdefi /httpboot/images/pxeboot/initrd.img
}
EOF
sudo sed -i 's/default="1"/default="3"/' "${GRUB_CFG}"
sudo sed -i 's/timeout=60/timeout=10/' "${GRUB_CFG}"

# Start httpd to serve ostree repo and HTTP boot server
greenprint "🚀 Starting httpd daemon"
sudo systemctl start httpd

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-${COMPOSE_ID}.json

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
    blueprint_file=$1
    blueprint_name=$2

    # Prepare the blueprint for the compose.
    greenprint "📋 Preparing blueprint"
    sudo composer-cli blueprints push "$blueprint_file"
    sudo composer-cli blueprints depsolve "$blueprint_name"

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!

    # Start the compose.
    greenprint "🚀 Starting compose"
    if [[ $blueprint_name == upgrade ]]; then
        # composer-cli in Fedora 32 has a different start-ostree arguments
        # see https://github.com/weldr/lorax/pull/1051
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" --parent "$COMMIT_HASH" "$blueprint_name" $IMAGE_TYPE | tee "$COMPOSE_START"
    else
        sudo composer-cli --json compose start "$blueprint_name" $IMAGE_TYPE | tee "$COMPOSE_START"
    fi
    # RHEL 8.6 and 9 use new command line tool weldr-client which has new response body
    if rpm -q --quiet weldr-client; then
        COMPOSE_ID=$(jq -r '.body.build_id' "$COMPOSE_START")
    else
        COMPOSE_ID=$(jq -r '.build_id' "$COMPOSE_START")
    fi

    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null

        # RHEL 8.6 and 9 use new command line tool weldr-client which has new response body
        if rpm -q --quiet weldr-client; then
            COMPOSE_STATUS=$(jq -r '.body.queue_status' "$COMPOSE_INFO")
        else
            COMPOSE_STATUS=$(jq -r '.queue_status' "$COMPOSE_INFO")
        fi

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

    # Did the compose finish with success?
    if [[ $COMPOSE_STATUS != FINISHED ]]; then
        echo "Something went wrong with the compose. 😢"
        exit 1
    fi

    # Stop watching the worker journal.
    sudo pkill -P ${WORKER_JOURNAL_PID}
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${1}" '/bin/bash -c "echo -n READY"')
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
    sudo virsh undefine "${IMAGE_KEY}" --nvram
    # Remove qcow2 file.
    sudo sudo virsh vol-delete --pool images "${IMAGE_KEY}.qcow2"
    # Remove extracted upgrade image-tar.
    sudo rm -rf "$UPGRADE_PATH"
    # Remove "remote" repo.
    sudo rm -rf "${HTTPD_PATH}"/{httpboot,repo,compose.json,ks.cfg}
    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"
    # Stop httpd
    sudo systemctl disable httpd --now
}

# Test result checking
check_result () {
    greenprint "Checking for test result"
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
## ostree image/commit installation
##
##################################################

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
EOF

# RHEL 8.5 and later support user configuration in blueprint for edge-commit image
if [[ "${USER_IN_COMMIT}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.user]]
name = "${SSH_USER}"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/${SSH_USER}/"
groups = ["wheel"]
EOF
fi

# Build installation image.
build_image "$BLUEPRINT_FILE" ostree

# Download the image and extract tar into web server root folder.
greenprint "📥 Downloading and extracting the image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
IMAGE_FILENAME="${COMPOSE_ID}-commit.tar"
sudo tar -xf "${IMAGE_FILENAME}" -C ${HTTPD_PATH}
sudo rm -f "$IMAGE_FILENAME"

# Clean compose and blueprints.
greenprint "Clean up osbuild-composer"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete ostree > /dev/null

# Get ostree commit value.
greenprint "Get ostree image commit value"
COMMIT_HASH=$(jq -r '."ostree-commit"' < ${HTTPD_PATH}/compose.json)

# Ensure SELinux is happy with our new images.
greenprint "👿 Running restorecon on image directory"
sudo restorecon -Rv /var/lib/libvirt/images/

# Create qcow2 file for virt install.
greenprint "Create qcow2 file for virt install"
LIBVIRT_IMAGE_PATH=/var/lib/libvirt/images/${IMAGE_KEY}.qcow2
sudo qemu-img create -f qcow2 "${LIBVIRT_IMAGE_PATH}" 20G

# Write kickstart file for ostree image installation.
greenprint "Generate kickstart file"
sudo tee "$KS_FILE" > /dev/null << STOPHERE
text
lang en_US.UTF-8
keyboard us
timezone --utc Etc/UTC
selinux --enforcing
rootpw --lock --iscrypted locked
user --name=${SSH_USER} --groups=wheel --iscrypted --password=\$6\$1LgwKw9aOoAi/Zy9\$Pn3ErY1E8/yEanJ98evqKEW.DZp24HTuqXPJl6GYCm8uuobAmwxLv7rGCvTRZhxtcYdmC0.XnYRSR9Sh6de3p0
sshkey --username=${SSH_USER} "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
bootloader --timeout=1 --append="net.ifnames=0 modprobe.blacklist=vc4"
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
ostreesetup --nogpg --osname=${IMAGE_TYPE} --remote=${IMAGE_TYPE} --url=http://192.168.100.1/repo/ --ref=${OSTREE_REF}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
# no sudo password for SSH user
echo -e '${SSH_USER}\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
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


# RHEL 8.5 and later configures user in blueprint for edge-commit image
if [[ "${USER_IN_COMMIT}" == "true" ]]; then
    sudo sed -i '/^user\|^sshkey/d' "${KS_FILE}"
fi

# Install ostree image via anaconda.
greenprint "Install ostree image via anaconda"
sudo virt-install  --name="${IMAGE_KEY}"\
                   --disk path="${LIBVIRT_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-type linux \
                   --os-variant ${OS_VARIANT} \
                   --pxe \
                   --boot uefi,loader_ro=yes,loader_type=pflash,nvram_template=/usr/share/edk2/ovmf/OVMF_VARS.fd,loader_secure=no \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${IMAGE_KEY}"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for LOOP_COUNTER in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

##################################################
##
## ostree image/commit upgrade
##
##################################################

# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "upgrade"
description = "An upgrade ostree image"
version = "0.0.2"
modules = []
groups = []
[[packages]]
name = "python3"
version = "*"
[[packages]]
name = "wget"
version = "*"
EOF

# RHEL 8.5 and later support user configuration in blueprint for edge-commit image
if [[ "${USER_IN_COMMIT}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.user]]
name = "${SSH_USER}"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/${SSH_USER}/"
groups = ["wheel"]
EOF
fi

# Build upgrade image.
build_image "$BLUEPRINT_FILE" upgrade

# Download the image and extract tar into web server root folder.
greenprint "📥 Downloading and extracting the image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
IMAGE_FILENAME="${COMPOSE_ID}-commit.tar"
UPGRADE_PATH="$(pwd)/upgrade"
mkdir -p "$UPGRADE_PATH"
sudo tar -xf "$IMAGE_FILENAME" -C "$UPGRADE_PATH"
sudo rm -f "$IMAGE_FILENAME"

# Clean compose and blueprints.
greenprint "Clean up osbuild-composer again"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete upgrade > /dev/null

# Introduce new ostree commit into repo.
greenprint "Introduce new ostree commit into repo"
sudo ostree pull-local --repo "${HTTPD_PATH}/repo" "${UPGRADE_PATH}/repo" "$OSTREE_REF"
sudo ostree summary --update --repo "${HTTPD_PATH}/repo"

# Ensure SELinux is happy with all objects files.
greenprint "👿 Running restorecon on web server root folder"
sudo restorecon -Rv "${HTTPD_PATH}/repo" > /dev/null

# Get ostree commit value.
greenprint "Get ostree image commit value"
UPGRADE_HASH=$(jq -r '."ostree-commit"' < "${UPGRADE_PATH}"/compose.json)

# Upgrade image/commit.
greenprint "Upgrade ostree image/commit"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo rpm-ostree upgrade'
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'

# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
# shellcheck disable=SC2034  # Unused variables left for readability
for LOOP_COUNTER in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check ostree upgrade result
check_result

# Add instance IP address into /etc/ansible/hosts
sudo tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${GUEST_ADDRESS}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Test IoT/Edge OS
sudo ansible-playbook -v -i "${TEMPDIR}"/inventory -e image_type=${IMAGE_TYPE} -e ostree_commit="${UPGRADE_HASH}" check-ostree.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0
