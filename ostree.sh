#!/bin/bash
set -exuo pipefail

# Provision the software under test.
./setup.sh

# Get OS data.
source /etc/os-release
ARCH=$(uname -m)

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="ostree-${TEST_UUID}"
GUEST_ADDRESS=192.168.100.50
SSH_USER="admin"
OS_NAME="rhel-edge"
IMAGE_TYPE=edge-commit

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
HTTPD_PATH="/var/www/html"
KS_FILE=${HTTPD_PATH}/ks.cfg
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json
GRUB_CFG=${HTTPD_PATH}/httpboot/EFI/BOOT/grub.cfg
EMBEDDED_CONTAINER="false"
# Workaround BZ#2108646
BOOT_ARGS="uefi"
FIREWALL_FEATURE="false"
# Mount /sysroot as RO by new ostree-libs-2022.6-3.el9.x86_64
# It's RHEL 9.2 and above, CS9, Fedora 37 and above ONLY
SYSROOT_RO="false"
FEDORA_IMAGE_DIGEST="sha256:4d76a7480ce1861c95975945633dc9d03807ffb45c64b664ef22e673798d414b"
FEDORA_LOCAL_NAME="localhost/fedora-minimal:v1"

# Set os-variant and boot location used by virt-install.
case "${ID}-${VERSION_ID}" in
    "rhel-8.10")
        OSTREE_REF="rhel/8/${ARCH}/edge"
        USER_IN_COMMIT="true"
        OS_VARIANT="rhel8-unknown"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-8/nightly/RHEL-8/latest-RHEL-8.10.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=8
        ADD_SSSD="true"
        EMBEDDED_CONTAINER="true"
        FIREWALL_FEATURE="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    "rhel-9.4")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        USER_IN_COMMIT="true"
        OS_VARIANT="rhel9-unknown"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/nightly/updates/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=9
        ADD_SSSD="true"
        EMBEDDED_CONTAINER="true"
        FIREWALL_FEATURE="true"
        SYSROOT_RO="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    "rhel-9.5")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        USER_IN_COMMIT="true"
        OS_VARIANT="rhel9-unknown"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.5.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=8
        ADD_SSSD="true"
        EMBEDDED_CONTAINER="true"
        FIREWALL_FEATURE="true"
        SYSROOT_RO="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    "rhel-9.6")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        USER_IN_COMMIT="true"
        OS_VARIANT="rhel9-unknown"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.6.0/compose/BaseOS/x86_64/os/"
        CUT_DIRS=8
        ADD_SSSD="true"
        EMBEDDED_CONTAINER="true"
        FIREWALL_FEATURE="true"
        SYSROOT_RO="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    "centos-9")
        OSTREE_REF="centos/9/${ARCH}/edge"
        USER_IN_COMMIT="true"
        OS_VARIANT="centos-stream9"
        CUT_DIRS=6
        ADD_SSSD="true"
        EMBEDDED_CONTAINER="true"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        FIREWALL_FEATURE="true"
        SYSROOT_RO="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    "fedora-41")
        IMAGE_TYPE=fedora-iot-commit
        USER_IN_COMMIT="false"
        OSTREE_REF="fedora/41/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        BOOT_LOCATION="https://dl.fedoraproject.org/pub/fedora/linux/releases/41/Everything/x86_64/os/"
        CUT_DIRS=8
        ADD_SSSD="false"
        SYSROOT_RO="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    "fedora-42")
        IMAGE_TYPE=fedora-iot-commit
        USER_IN_COMMIT="false"
        OSTREE_REF="fedora/42/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        BOOT_LOCATION="https://dl.fedoraproject.org/pub/fedora/linux/development/42/Everything/x86_64/os/"
        CUT_DIRS=8
        ADD_SSSD="false"
        SYSROOT_RO="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    "fedora-43")
        IMAGE_TYPE=fedora-iot-commit
        USER_IN_COMMIT="false"
        OSTREE_REF="fedora/43/${ARCH}/iot"
        OS_VARIANT="fedora-rawhide"
        BOOT_LOCATION="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/"
        CUT_DIRS=8
        ADD_SSSD="false"
        SYSROOT_RO="true"
        DIRS_FILES_CUSTOMIZATION="true"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# For CentOS Stream test, do not use latest link but use COMPOSE ID URL instead to work around issue
# https://bugzilla.redhat.com/show_bug.cgi?id=2065708
if [[ "${ID}-${VERSION_ID}" == "centos-9" ]]; then
    CURRENT_COMPOSE_CS9=$(curl -s "https://composes.stream.centos.org/production/" | grep -ioE ">CentOS-Stream-9-.*/<" | tr -d '>/<' | tail -1)
    BOOT_LOCATION="https://composes.stream.centos.org/production/${CURRENT_COMPOSE_CS9}/compose/BaseOS/x86_64/os/"
fi

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Download HTTP boot required files
greenprint "📥 Download HTTP boot required files"
sudo rm -rf "${HTTPD_PATH}/httpboot"
sudo mkdir -p "${HTTPD_PATH}/httpboot"
REQUIRED_FOLDERS=( "EFI" "images" )
for i in "${REQUIRED_FOLDERS[@]}"
do
    sudo wget -q --inet4-only -r --no-parent -e robots=off -nH --cut-dirs="$CUT_DIRS" --reject "index.html*" --reject "boot.iso" "${BOOT_LOCATION}${i}/" -P "${HTTPD_PATH}/httpboot/"
done

# Update grub.cfg to work with HTTP boot
greenprint "📝 Update grub.cfg to work with HTTP boot"
sudo tee -a "${GRUB_CFG}" > /dev/null << EOF
menuentry 'Install Red Hat Enterprise Linux for Edge' --class fedora --class gnu-linux --class gnu --class os {
        linuxefi /httpboot/images/pxeboot/vmlinuz inst.stage2=http://192.168.100.1/httpboot inst.ks=http://192.168.100.1/ks.cfg inst.text console=ttyS0,115200
        initrdefi /httpboot/images/pxeboot/initrd.img
}
EOF
sudo sed -i 's/default="1"/default="3"/' "${GRUB_CFG}"
sudo sed -i 's/timeout=60/timeout=10/' "${GRUB_CFG}"

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key

# Compare rpm package version
function nvrGreaterOrEqual {
    local rpm_name=$1
    local min_version=$2

    set +e

    rpm_version=$(rpm -q --qf "%{version}" "${rpm_name}")
    rpmdev-vercmp "${rpm_version}" "${min_version}" 1>&2
    if [ "$?" != "12" ]; then
        # 0 - rpm_version == min_version
        # 11 - rpm_version > min_version
        # 12 - rpm_version < min_version
        set -e
        return
    fi

    set -e
    false
}

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
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" $IMAGE_TYPE | tee "$COMPOSE_START"
    else
        sudo composer-cli --json compose start "$blueprint_name" $IMAGE_TYPE | tee "$COMPOSE_START"
    fi

    if nvrGreaterOrEqual "weldr-client" "35.6"; then
        COMPOSE_ID=$(jq -r '.[0].body.build_id' "$COMPOSE_START")
    else
        COMPOSE_ID=$(jq -r '.body.build_id' "$COMPOSE_START")
    fi

    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null

        if nvrGreaterOrEqual "weldr-client" "35.6"; then
            COMPOSE_STATUS=$(jq -r '.[0].body.queue_status' "$COMPOSE_INFO")
        else
            COMPOSE_STATUS=$(jq -r '.body.queue_status' "$COMPOSE_INFO")
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
    sudo virsh vol-delete --pool images "${IMAGE_KEY}.qcow2"
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

# For BZ#2088459, RHEL 8.6 and 9.0 will not have new release which fix this issue
# RHEL 8.6 and 9.0 will not include sssd package in blueprint
if [[ "${ADD_SSSD}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[packages]]
name = "sssd"
version = "*"
EOF
fi

# Fedora does not support user configuration in blueprint for fedora-iot-commit image
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

# RHEL 8.7 and 9.1 later support embedded container in commit
if [[ "${EMBEDDED_CONTAINER}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[containers]]
source = "quay.io/fedora/fedora:latest"

[[containers]]
source = "registry.gitlab.com/redhat/services/products/image-builder/ci/osbuild-composer/fedora-minimal@${FEDORA_IMAGE_DIGEST}"
name = "${FEDORA_LOCAL_NAME}"
EOF
fi

# Add directory and files customization, and services customization for testing
if [[ "${DIRS_FILES_CUSTOMIZATION}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.directories]]
path = "/etc/custom_dir/dir1"
user = 1020
group = 1020
mode = "0770"
ensure_parents = true

[[customizations.files]]
path = "/etc/systemd/system/custom.service"
data = "[Unit]\nDescription=Custom service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/false\n[Install]\nWantedBy=multi-user.target\n"

[[customizations.files]]
path = "/etc/custom_file.txt"
data = "image builder is the best\n"

[[customizations.directories]]
path = "/etc/systemd/system/custom.service.d"

[[customizations.files]]
path = "/etc/systemd/system/custom.service.d/override.conf"
data = "[Service]\nExecStart=\nExecStart=/usr/bin/cat /etc/custom_file.txt\n"

[customizations.services]
enabled = ["custom.service"]
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
ostreesetup --nogpg --osname=${OS_NAME} --remote=${OS_NAME} --url=http://192.168.100.1/repo/ --ref=${OSTREE_REF}
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

# Fedora does not support user configuration in blueprint for fedora-iot-commit image
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
                   --boot ${BOOT_ARGS} \
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
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'
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
[[customizations.user]]
name = "${SSH_USER}"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/${SSH_USER}/"
groups = ["wheel"]
EOF

# For BZ#2088459, RHEL 8.6 and 9.0 will not have new release which fix this issue
# RHEL 8.6 and 9.0 will not include sssd package in blueprint
if [[ "${ADD_SSSD}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[packages]]
name = "sssd"
version = "*"
EOF
fi

# RHEL 8.7 and 9.1 later support embedded container in commit
if [[ "${EMBEDDED_CONTAINER}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[containers]]
source = "quay.io/fedora/fedora:latest"

[[containers]]
source = "registry.gitlab.com/redhat/services/products/image-builder/ci/osbuild-composer/fedora-minimal@${FEDORA_IMAGE_DIGEST}"
name = "${FEDORA_LOCAL_NAME}"
EOF
fi

if [[ "${FIREWALL_FEATURE}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.firewall.zones]]
name = "trusted"
sources = ["192.168.100.51"]
[[customizations.firewall.zones]]
name = "work"
sources = ["192.168.100.52"]
EOF
fi

# Add directory and files customization, and services customization for testing
if [[ "${DIRS_FILES_CUSTOMIZATION}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[customizations.directories]]
path = "/etc/custom_dir/dir1"
user = 1020
group = 1020
mode = "0770"
ensure_parents = true

[[customizations.files]]
path = "/etc/systemd/system/custom.service"
data = "[Unit]\nDescription=Custom service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/false\n[Install]\nWantedBy=multi-user.target\n"

[[customizations.files]]
path = "/etc/custom_file.txt"
data = "image builder is the best\n"

[[customizations.directories]]
path = "/etc/systemd/system/custom.service.d"

[[customizations.files]]
path = "/etc/systemd/system/custom.service.d/override.conf"
data = "[Service]\nExecStart=\nExecStart=/usr/bin/cat /etc/custom_file.txt\n"

[customizations.services]
enabled = ["custom.service"]
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

# Remove upgrade repo
sudo rm -rf "$UPGRADE_PATH"

# Upgrade image/commit.
greenprint "Upgrade ostree image/commit"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'sudo rpm-ostree upgrade'
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'

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

# Check ostree upgrade result
check_result

# Add instance IP address into /etc/ansible/hosts
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${GUEST_ADDRESS}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${SSH_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Test IoT/Edge OS
podman run --network=host --annotation run.oci.keep_original_groups=1 -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory -e os_name="${OS_NAME}" -e ostree_commit="${UPGRADE_HASH}" -e ostree_ref="${OS_NAME}:${OSTREE_REF}" -e embedded_container="${EMBEDDED_CONTAINER}" -e firewall_feature="${FIREWALL_FEATURE}" -e sysroot_ro="$SYSROOT_RO" -e test_custom_dirs_files="${DIRS_FILES_CUSTOMIZATION}" check-ostree.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0
