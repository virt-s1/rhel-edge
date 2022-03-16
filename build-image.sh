#!/bin/bash
set -euox pipefail

# normal kernel or RT kernel
IMAGE_KERNEL="normal"
if [[ $1 == "rt" ]]; then
    IMAGE_KERNEL="rt"
fi

# Provision the software under test.
./setup.sh

# Get OS data.
source /etc/os-release

# Set up variables.
ARCH=$(uname -m)
TEST_UUID=$(uuidgen)
IMAGE_KEY="rhel-edge-test-${TEST_UUID}"
QUAY_REPO_URL="docker://quay.io/rhel-edge/edge-containers"
CONTAINER_IMAGE_TYPE=edge-container
CONTAINER_FILENAME=container.tar

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json


case "${ID}-${VERSION_ID}" in
    "rhel-8.6")
        OSTREE_REF="rhel/8/${ARCH}/edge"
        TAG=rhel-8-6
        ;;
    "rhel-9.0")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        TAG=rhel-9-0
        ;;
    "centos-8")
        OSTREE_REF="centos/8/${ARCH}/edge"
        TAG=cs8
        ;;
    "centos-9")
        OSTREE_REF="centos/9/${ARCH}/edge"
        TAG=cs9
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

OCP4_REPO_URL="http://edge-${TAG}-${IMAGE_KERNEL}-rhel-edge.apps.ocp-c1.prod.psi.redhat.com/repo/"

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-build-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-build-${COMPOSE_ID}.json

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
    sudo kill ${WORKER_JOURNAL_PID}
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"

    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"
}

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
name = "python3"
version = "*"

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/admin/"
groups = ["wheel"]
EOF

if [[ "${IMAGE_KERNEL}" == "rt" ]]; then
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

# Deal with rhel-edge container
greenprint "Uploading image to quay.io"
IMAGE_FILENAME="${COMPOSE_ID}-${CONTAINER_FILENAME}"
sudo skopeo copy --dest-creds "${QUAY_USERNAME}:${QUAY_PASSWORD}" "oci-archive:${IMAGE_FILENAME}" "${QUAY_REPO_URL}:${TAG}-${IMAGE_KERNEL}"
# Clear image file
sudo rm -f "$IMAGE_FILENAME"

# Run edge repo in OCP4
greenprint "Running edge repo in OCP4"
oc login --token="${OCP4_TOKEN}" --server=https://api.ocp-c1.prod.psi.redhat.com:6443 -n rhel-edge --insecure-skip-tls-verify
# Delete old app
oc delete pod,rc,service,route,dc -l app="edge-${TAG}-${IMAGE_KERNEL}"
oc process -f tools/edge-stage-server-template.yaml -p EDGE_STAGE_REPO_TAG="${TAG}-${IMAGE_KERNEL}" -p EDGE_STAGE_SERVER_NAME="edge" | oc apply -f -

for _ in $(seq 0 60); do
    RETURN_CODE=$(curl -o /dev/null -s -w "%{http_code}" "${OCP4_REPO_URL}refs/heads/${OSTREE_REF}")
    if [[ $RETURN_CODE == 200 ]]; then
        echo "edge repo is ready"
        break
    fi
    sleep 10
done

# Clean compose and blueprints.
greenprint "🧹 Clean up compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete container > /dev/null

clean_up

exit 0
