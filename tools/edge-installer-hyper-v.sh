#!/bin/bash
set -euox pipefail

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

# Customize repository
sudo mkdir -p /etc/osbuild-composer/repositories

# Set up variables.
ARCH=$(uname -m)
TEST_UUID=$(uuidgen)
IMAGE_KEY="rhel-edge-test-${TEST_UUID}"
PROD_REPO=/var/www/html/repo
STAGE_REPO_ADDRESS=192.168.200.1

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json

case "${ID}-${VERSION_ID}" in
    "rhel-8.4")
        CONTAINER_IMAGE_TYPE=rhel-edge-container
        INSTALLER_IMAGE_TYPE=rhel-edge-installer
        CONTAINER_FILENAME=rhel84-container.tar
        INSTALLER_FILENAME=rhel84-boot.iso
        OSTREE_REF="rhel/8/${ARCH}/edge"
        PROD_REPO_URL=http://192.168.100.1/repo/
        PROD_REPO_URL_2=$PROD_REPO_URL
        RT_TO_RT="true"
        STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}/repo/"
        sudo cp files/rhel-8-4-0.json /etc/osbuild-composer/repositories/rhel-8-beta.json
        sudo ln -sf /etc/osbuild-composer/repositories/rhel-8-beta.json /etc/osbuild-composer/repositories/rhel-8.json;;
    "rhel-8.5")
        CONTAINER_IMAGE_TYPE=edge-container
        INSTALLER_IMAGE_TYPE=edge-installer
        CONTAINER_FILENAME=container.tar
        INSTALLER_FILENAME=installer.iso
        OSTREE_REF="rhel/8/${ARCH}/edge"
        PROD_REPO_URL=http://192.168.100.1/repo
        PROD_REPO_URL_2="${PROD_REPO_URL}/"
        RT_TO_RT="false"
        STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"
        sudo cp files/rhel-8-5-0.json /etc/osbuild-composer/repositories/rhel-85.json;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Install required packages
greenprint "Install required packages"
sudo dnf install -y --nogpgcheck httpd osbuild osbuild-composer composer-cli podman wget firewalld

# Start httpd server as prod ostree repo
greenprint "Start httpd service"
sudo systemctl enable --now httpd.service

# Start osbuild-composer.socket
greenprint "Start osbuild-composer.socket"
sudo systemctl enable --now osbuild-composer.socket

# Start firewalld
greenprint "Start firewalld"
sudo systemctl enable --now firewalld

# modify existing kickstart by prepending and appending commands
function modksiso {
    sudo dnf install -y lorax  # for mkksiso
    isomount=$(mktemp -d)
    kspath=$(mktemp -d)

    iso="$1"
    newiso="$2"

    echo "Mounting ${iso} -> ${isomount}"
    sudo mount -v -o ro "${iso}" "${isomount}"

    cleanup() {
        sudo umount -v "${isomount}"
        rmdir -v "${isomount}"
        rm -rv "${kspath}"
    }

    trap cleanup RETURN

    ksfiles=("${isomount}"/*.ks)
    ksfile="${ksfiles[0]}"  # there shouldn't be more than one anyway
    echo "Found kickstart file ${ksfile}"

    ksbase=$(basename "${ksfile}")
    newksfile="${kspath}/${ksbase}"
    oldks=$(cat "${ksfile}")
    echo "Preparing modified kickstart file"
    cat > "${newksfile}" << EOFKS
text
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
${oldks}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
# no sudo password for user admin and installeruser
echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
echo -e 'installeruser\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
# add remote prod edge repo
ostree remote delete rhel
ostree remote add --no-gpg-verify --no-sign-verify rhel ${PROD_REPO_URL}
%end
EOFKS

    echo "Writing new ISO"
    sudo mkksiso -c "console=ttyS0,115200" "${newksfile}" "${iso}" "${newiso}"

    echo "==== NEW KICKSTART FILE ===="
    cat "${newksfile}"
    echo "============================"
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-ng-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-ng-${COMPOSE_ID}.json

    # Download the metadata.
    sudo composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    tar -xf "$TARBALL" -C "${TEMPDIR}"
    rm -f "$TARBALL"

    # Move the JSON file into place.
    cat "${TEMPDIR}"/"${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
}

# Build ostree image.
build_image() {
    blueprint_name=$1
    image_type=$2

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.socket")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!

    # Start the compose.
    greenprint "🚀 Starting compose"
    if [ $# -eq 3 ]; then
        repo_url=$3
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" --url "$repo_url" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    else
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    fi
    COMPOSE_ID=$(jq -r '.build_id' "$COMPOSE_START")

    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null
        COMPOSE_STATUS=$(jq -r '.queue_status' "$COMPOSE_INFO")

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
    sudo kill ${WORKER_JOURNAL_PID}
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"

    # Remove all the containers and images if exist
    sudo podman system reset --force

    # Remove prod repo.
    sudo rm -rf "$PROD_REPO"

    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"

    # Stop httpd
    sudo systemctl disable httpd --now
}

###########################################################
##
## Prepare ostree prod repo and configure stage repo
##
###########################################################
greenprint "Prepare ostree prod repo and configure stage repo"
sudo rm -rf "$PROD_REPO"
sudo mkdir -p "$PROD_REPO"
sudo ostree --repo="$PROD_REPO" init --mode=archive
sudo ostree --repo="$PROD_REPO" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"

###########################################################
##
## rhel-edge container image for building installer image
##
###########################################################

# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "container"
description = "A base rhel-edge container image"
version = "0.0.1"
modules = []
groups = []

[[packages]]
name = "hyperv-daemons"
version = "*"

[[packages]]
name = "python36"
version = "*"

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/admin/"
groups = ["wheel"]
EOF

if [[ "${RT_TO_RT}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[customizations.kernel]
name = "kernel-rt"
EOF
fi

greenprint "📄 Which blueprint are we using"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve container

# Build container image.
build_image container "${CONTAINER_IMAGE_TYPE}"

# Download the image
greenprint "📥 Downloading the image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null

# Clear container running env
greenprint "🧹 Clearing container running env"
# Remove any status containers if exist
sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
# Remove all images
sudo podman rmi -f -a

# Prepare rhel-edge container network
greenprint "Prepare container network"
sudo podman network inspect edge >/dev/null 2>&1 || sudo podman network create --driver=bridge --subnet=192.168.200.0/24 --gateway=192.168.200.254 edge

# Deal with stage repo image
greenprint "🗜 Starting container"
IMAGE_FILENAME="${COMPOSE_ID}-${CONTAINER_FILENAME}"
sudo podman pull "oci-archive:${IMAGE_FILENAME}"
sudo podman images

# Run edge stage repo
greenprint "🛰 Running edge stage repo"
# Get image id to run image
EDGE_IMAGE_ID=$(sudo podman images --filter "dangling=true" --format "{{.ID}}")
sudo podman run -d --name rhel-edge --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Clear image file
sudo rm -f "$IMAGE_FILENAME"

# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' rhel-edge)" == "true" ]; do
    sleep 1;
done;

# Sync installer ostree content
greenprint "Sync ostree repo with stage repo"
sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage "$OSTREE_REF"


# Clean compose and blueprints.
greenprint "🧹 Clean up compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete container > /dev/null

########################################################
##
## rhel-edge installer image building from container image
##
########################################################

# Write a blueprint for installer image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "installer"
description = "A base rhel-edge installer image"
version = "0.0.1"
modules = []
groups = []
EOF

greenprint "📄 Which blueprint are we using"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve installer

# Build installer image.
# Test --url arg following by URL with tailling slash for bz#1942029
build_image installer "${INSTALLER_IMAGE_TYPE}" "${PROD_REPO_URL_2}"

# Download the image
greenprint "📥 Downloading the image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
ISO_FILENAME="${COMPOSE_ID}-${INSTALLER_FILENAME}"
modksiso "${ISO_FILENAME}" "hyper-v-${ISO_FILENAME}"
sudo rm "${ISO_FILENAME}"

# Clean compose and blueprints.
greenprint "🧹 Clean up compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete installer > /dev/null

clean_up

exit 0
