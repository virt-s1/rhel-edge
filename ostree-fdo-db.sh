#!/bin/bash
set -euox pipefail

# Provision the software under test.
./setup.sh

source /etc/os-release
ARCH=$(uname -m)

# Set up variables.
TEST_UUID=$(uuidgen)
IMAGE_KEY="ostree-installer-${TEST_UUID}"
PUB_KEY_GUEST_ADDRESS=192.168.100.51
PROD_REPO_URL=http://192.168.100.1/repo
PROD_REPO=/var/www/html/repo
STAGE_REPO_ADDRESS=192.168.200.1
STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"
FDO_SERVER_ADDRESS=192.168.100.1
CONTAINER_TYPE=edge-container
CONTAINER_FILENAME=container.tar
INSTALLER_TYPE=edge-simplified-installer
INSTALLER_FILENAME=simplified-installer.iso
REF_PREFIX="rhel-edge"

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)

FDO_USER=fdouser
SYSROOT_RO="true"

case "${ID}-${VERSION_ID}" in
    "rhel-9.4")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9-unknown"
        BOOT_ARGS="uefi"
        ;;
    "centos-9")
        OSTREE_REF="centos/9/${ARCH}/edge"
        OS_VARIANT="centos-stream9"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-installer-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-installer-${COMPOSE_ID}.json

    # Download the metadata.
    sudo composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    sudo tar -xf "$TARBALL" -C "${TEMPDIR}"
    sudo rm -f "$TARBALL"

    # Move the JSON file into place.
    sudo cat "${TEMPDIR}"/"${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
    sudo rm -f "${TEMPDIR}"/"${COMPOSE_ID}".json
}

# Build ostree image.
build_image() {
    blueprint_name=$1
    image_type=$2

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.service")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!
    # Stop watching the worker journal when exiting.
    trap 'sudo pkill -P ${WORKER_JOURNAL_PID}' EXIT

    # Start the compose.
    greenprint "🚀 Starting compose"
    if [ $# -eq 3 ]; then
        repo_url=$3
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" --url "$repo_url" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    else
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
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
        echo "Something went wrong with the compose. 😢"
        exit 1
    fi
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@"${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Wait for FDO onboarding finished.
wait_for_fdo () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@"${1}" "id -u $FDO_USER > /dev/null 2>&1 && echo -n READY")
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"

    # Remove any status containers if exist
    sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
    # Remove all images
    sudo podman rmi -f -a

    # Remove prod repo
    sudo rm -rf "$PROD_REPO"

    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"

    # Stop prod repo http service
    sudo systemctl disable --now httpd
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

import_ov () {
    greenprint "🔧 Export OV and import into owner db"
    mkdir -p "${TEMPDIR}/export-ov"
    if [[ $DB_TYPE == 0 ]]; then
        sudo /usr/libexec/fdo/fdo-owner-tool export-manufacturer-vouchers sqlite "${manufacturer_db_file}" "${TEMPDIR}/export-ov/"
        EXPORTED_FILE=$(ls -1 "${TEMPDIR}/export-ov")
        sudo /usr/libexec/fdo/fdo-owner-tool import-ownership-vouchers sqlite "${owner_db_file}" "${TEMPDIR}/export-ov/${EXPORTED_FILE}"
    else
        /usr/libexec/fdo/fdo-owner-tool export-manufacturer-vouchers postgres "postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}/${POSTGRES_DB}" "${TEMPDIR}/export-ov/"
        EXPORTED_FILE=$(ls -1 "${TEMPDIR}/export-ov")
        /usr/libexec/fdo/fdo-owner-tool import-ownership-vouchers postgres "postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}/${POSTGRES_DB}" "${TEMPDIR}/export-ov/${EXPORTED_FILE}"
    fi
    rm -rf "${TEMPDIR}/export-ov"
}

###########################################################
##
## Prepare edge prod and stage repo
##
###########################################################
# Have a clean prod repo
greenprint "🔧 Prepare edge prod repo"
sudo rm -rf "$PROD_REPO"
sudo mkdir -p "$PROD_REPO"
sudo ostree --repo="$PROD_REPO" init --mode=archive
sudo ostree --repo="$PROD_REPO" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"

# Prepare stage repo network
greenprint "🔧 Prepare stage repo network"
sudo podman network inspect edge >/dev/null 2>&1 || sudo podman network create --driver=bridge --subnet=192.168.200.0/24 --gateway=192.168.200.254 edge

# Clear container running env
greenprint "🧹 Clearing container running env"
# Remove any status containers if exist
sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
# Remove all images
sudo podman rmi -f -a

##########################################################
##
## Prepare FDO servers with DB
##
##########################################################
# Disable selinux as workaround
sudo setenforce 0
getenforce

# Install dependencies
greenprint "🔧 Install FDO and other dependencies"
sudo dnf install -y fdo-admin-cli fdo-rendezvous-server fdo-owner-onboarding-server fdo-owner-cli fdo-manufacturing-server
sudo dnf install -y make gcc openssl openssl-devel findutils golang git tpm2-tss-devel \
    swtpm swtpm-tools git clevis clevis-luks cryptsetup cryptsetup-devel clang-devel \
    cracklib-dicts sqlite sqlite-devel libpq libpq-devel cargo python3-pip
sudo pip3 install yq

# Generate FDO key and configuration files
greenprint "🔧 Generate FDO key and configuration files"
sudo mkdir -p /etc/fdo/keys
for obj in diun manufacturer device-ca owner; do
    sudo fdo-admin-tool generate-key-and-cert --destination-dir /etc/fdo/keys "$obj"
done
DIUN_PUB_KEY_HASH=sha256:$(openssl x509 -fingerprint -sha256 -noout -in /etc/fdo/keys/diun_cert.pem | cut -d"=" -f2 | sed 's/://g')

sudo mkdir -p \
    /etc/fdo/manufacturing-server.conf.d/ \
    /etc/fdo/owner-onboarding-server.conf.d/ \
    /etc/fdo/rendezvous-server.conf.d/ \
    /etc/fdo/serviceinfo-api-server.conf.d/
sudo cp files/fdo/manufacturing-server.yml /etc/fdo/manufacturing-server.conf.d/
sudo cp files/fdo/owner-onboarding-server.yml /etc/fdo/owner-onboarding-server.conf.d/
sudo cp files/fdo/rendezvous-server.yml /etc/fdo/rendezvous-server.conf.d/
sudo cp files/fdo/serviceinfo-api-server.yml /etc/fdo/serviceinfo-api-server.conf.d/

# Other FDO configurations
sudo /usr/local/bin/yq -iy '.service_info.diskencryption_clevis |= [{disk_label: "/dev/vda4", reencrypt: true, binding: {pin: "tpm2", config: "{}"}}]' /etc/fdo/serviceinfo-api-server.conf.d/serviceinfo-api-server.yml
sudo /usr/local/bin/yq -iy '.service_info.initial_user |= {username: "fdouser", sshkeys: ["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"]}' /etc/fdo/serviceinfo-api-server.conf.d/serviceinfo-api-server.yml
sudo tee /var/lib/fdo/fdouser > /dev/null << EOF
fdouser ALL=(ALL) NOPASSWD: ALL
EOF
sudo /usr/local/bin/yq -iy '.service_info.files |= [{path: "/etc/sudoers.d/fdouser", source_path: "/var/lib/fdo/fdouser"}]' /etc/fdo/serviceinfo-api-server.conf.d/serviceinfo-api-server.yml

# Setup FDO database
DB_TYPE=$((RANDOM % 2))
if [[ $DB_TYPE == 0 ]]; then
    # Setup FDO SQLite database
    greenprint "🔧 FDO SQLite DB configurations"
    cargo install --force diesel_cli --no-default-features --features sqlite
    rm -fr /tmp/fdo
    mkdir -p /tmp/fdo
    manufacturer_db_file="/tmp/fdo/manufacturer-db.sqlite"
    owner_db_file="/tmp/fdo/owner-db.sqlite"
    rendezvous_db_file="/tmp/fdo/rendezvous-db.sqlite"
    ~/.cargo/bin/diesel migration run --migration-dir /usr/share/doc/fdo/migrations/migrations_manufacturing_server_sqlite --database-url "${manufacturer_db_file}"
    ~/.cargo/bin/diesel migration run --migration-dir /usr/share/doc/fdo/migrations/migrations_owner_onboarding_server_sqlite --database-url "${owner_db_file}"
    ~/.cargo/bin/diesel migration run --migration-dir /usr/share/doc/fdo/migrations/migrations_rendezvous_server_sqlite --database-url "${rendezvous_db_file}"

    tee "create_table.sql" > /dev/null << EOF
CREATE TABLE manufacturer_vouchers (
    guid varchar(36) NOT NULL PRIMARY KEY,
    contents blob NOT NULL,
    ttl bigint
);
EOF
    sqlite3 "${manufacturer_db_file}" < create_table.sql

    tee "create_table.sql" > /dev/null << EOF
CREATE TABLE owner_vouchers (
    guid varchar(36) NOT NULL PRIMARY KEY,
    contents blob NOT NULL,
    to2_performed bool,
    to0_accept_owner_wait_seconds bigint
);
EOF
    sqlite3 "${owner_db_file}" < create_table.sql

    tee "create_table.sql" > /dev/null << EOF
CREATE TABLE rendezvous_vouchers (
    guid varchar(36) NOT NULL PRIMARY KEY,
    contents blob NOT NULL,
    ttl bigint
);
EOF
    sqlite3 "${rendezvous_db_file}" < create_table.sql

    # Update FDO configuration files
    greenprint "🔧 Update FDO configuration files"
    sudo /usr/local/bin/yq -yi 'del(.ownership_voucher_store_driver.Directory)' /etc/fdo/manufacturing-server.conf.d/manufacturing-server.yml
    sudo /usr/local/bin/yq -yi '.ownership_voucher_store_driver += {"Sqlite": "Manufacturer"}' /etc/fdo/manufacturing-server.conf.d/manufacturing-server.yml
    sudo /usr/local/bin/yq -yi 'del(.ownership_voucher_store_driver.Directory)' /etc/fdo/owner-onboarding-server.conf.d/owner-onboarding-server.yml
    sudo /usr/local/bin/yq -yi '.ownership_voucher_store_driver += {"Sqlite": "Owner"}' /etc/fdo/owner-onboarding-server.conf.d/owner-onboarding-server.yml
    sudo /usr/local/bin/yq -yi 'del(.storage_driver.Directory)' /etc/fdo/rendezvous-server.conf.d/rendezvous-server.yml
    sudo /usr/local/bin/yq -yi '.storage_driver += {"Sqlite": "Rendezvous"}' /etc/fdo/rendezvous-server.conf.d/rendezvous-server.yml

    # Update FDO service unit file
    sudo sed -i \
        "/Environment=LOG_LEVEL=info/a Environment=SQLITE_MANUFACTURER_DATABASE_URL=${manufacturer_db_file}" \
        /usr/lib/systemd/system/fdo-manufacturing-server.service
    sudo sed -i \
        "/Environment=LOG_LEVEL=info/a Environment=SQLITE_OWNER_DATABASE_URL=${owner_db_file}" \
        /usr/lib/systemd/system/fdo-owner-onboarding-server.service
    sudo sed -i \
        "/Environment=LOG_LEVEL=info/a Environment=SQLITE_RENDEZVOUS_DATABASE_URL=${rendezvous_db_file}" \
        /usr/lib/systemd/system/fdo-rendezvous-server.service
else
    # Setup FDO POSTGRES database
    greenprint "🔧 FDO Postgres DB configurations"
    POSTGRES_USERNAME=postgres
    POSTGRES_PASSWORD=foobar
    POSTGRES_DB=postgres
    POSTGRES_IP=192.168.200.2

    # Prepare postgres db init sql script
    greenprint "🔧 Prepare postgres db init sql script"
    mkdir -p initdb
    cp /usr/share/doc/fdo/migrations/migrations_manufacturing_server_postgres/up.sql initdb/manufacturing.sql
    cp /usr/share/doc/fdo/migrations/migrations_owner_onboarding_server_postgres/up.sql initdb/owner-onboarding.sql
    cp /usr/share/doc/fdo/migrations/migrations_rendezvous_server_postgres/up.sql initdb/rendezvous.sql

    greenprint "🔧 Starting postgres"
    sudo podman run -d \
        --ip "$POSTGRES_IP" \
        --name postgres \
        --network edge \
        -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        -v "$PWD"/initdb/:/docker-entrypoint-initdb.d/:z \
        "quay.io/xiaofwan/postgres"
    until sudo podman exec postgres pg_isready
    do
        sleep 5
    done

    # Set servers store driver to postgres
    greenprint "🔧 Set servers store driver to postgres"
    sudo /usr/local/bin/yq -yi 'del(.ownership_voucher_store_driver.Directory)' /etc/fdo/manufacturing-server.conf.d/manufacturing-server.yml
    sudo /usr/local/bin/yq -yi '.ownership_voucher_store_driver += {"Postgres": "Manufacturer"}' /etc/fdo/manufacturing-server.conf.d/manufacturing-server.yml
    sudo /usr/local/bin/yq -yi 'del(.ownership_voucher_store_driver.Directory)' /etc/fdo/owner-onboarding-server.conf.d/owner-onboarding-server.yml
    sudo /usr/local/bin/yq -yi '.ownership_voucher_store_driver += {"Postgres": "Owner"}' /etc/fdo/owner-onboarding-server.conf.d/owner-onboarding-server.yml
    sudo /usr/local/bin/yq -yi 'del(.storage_driver.Directory)' /etc/fdo/rendezvous-server.conf.d/rendezvous-server.yml
    sudo /usr/local/bin/yq -yi '.storage_driver += {"Postgres": "Rendezvous"}' /etc/fdo/rendezvous-server.conf.d/rendezvous-server.yml

    # Configure environment variables for Postgres connection
    greenprint "🔧 Configure environment variables for Postgres connection"
    sudo sed -i \
        "/Environment=LOG_LEVEL=info/a Environment=POSTGRES_MANUFACTURER_DATABASE_URL=postgresql:\/\/${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}\/${POSTGRES_DB}" \
        /usr/lib/systemd/system/fdo-manufacturing-server.service
    sudo sed -i \
        "/Environment=LOG_LEVEL=info/a Environment=POSTGRES_OWNER_DATABASE_URL=postgresql:\/\/${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}\/${POSTGRES_DB}" \
        /usr/lib/systemd/system/fdo-owner-onboarding-server.service
    sudo sed -i \
        "/Environment=LOG_LEVEL=info/a Environment=POSTGRES_RENDEZVOUS_DATABASE_URL=postgresql:\/\/${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}\/${POSTGRES_DB}" \
        /usr/lib/systemd/system/fdo-rendezvous-server.service
fi

# Start FDO services
greenprint "🔧 Start all FDO services"
sudo systemctl daemon-reload
sudo systemctl start \
    fdo-owner-onboarding-server.service \
    fdo-rendezvous-server.service \
    fdo-manufacturing-server.service \
    fdo-serviceinfo-api-server.service

# Check FDO service status
sleep 10
until [ "$(curl -X POST http://${FDO_SERVER_ADDRESS}:8080/ping)" == "pong" ]; do
    sleep 1;
done;

until [ "$(curl -X POST http://${FDO_SERVER_ADDRESS}:8081/ping)" == "pong" ]; do
    sleep 1;
done;

until [ "$(curl -X POST http://${FDO_SERVER_ADDRESS}:8082/ping)" == "pong" ]; do
    sleep 1;
done;

##########################################################
##
## Build edge-container image and start it in podman
##
##########################################################
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
EOF

greenprint "📄 container blueprint"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing container blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve container

# Build container image.
build_image container "${CONTAINER_TYPE}"

# Download the image
greenprint "📥 Downloading the container image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null

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

# Sync installer edge content
greenprint "📡 Sync installer content from stage repo"
sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage "$OSTREE_REF"

# Clean compose and blueprints.
greenprint "🧽 Clean up container blueprint and compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete container > /dev/null

####################################################################
##
## Build edge-simplified-installer with diun_pub_key_hash enabled
##
####################################################################
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "fdosshkey"
description = "A rhel-edge simplified-installer image"
version = "0.0.1"
modules = []
groups = []

[customizations]
installation_device = "/dev/vda"

[customizations.fdo]
manufacturing_server_url="http://${FDO_SERVER_ADDRESS}:8080"
diun_pub_key_hash="${DIUN_PUB_KEY_HASH}"

[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "${SSH_KEY_PUB}"
home = "/home/admin/"
groups = ["wheel"]
EOF

greenprint "📄 fdosshkey blueprint"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing fdosshkey blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve fdosshkey

# Build fdosshkey image.
build_image fdosshkey "${INSTALLER_TYPE}" "${PROD_REPO_URL}"

# Download the image
greenprint "📥 Downloading the fdosshkey image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
ISO_FILENAME="${COMPOSE_ID}-${INSTALLER_FILENAME}"
sudo mv "${ISO_FILENAME}" /var/lib/libvirt/images

# Clean compose and blueprints.
greenprint "🧹 Clean up fdosshkey blueprint and compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete fdosshkey > /dev/null

# Create qcow2 file for virt install.
greenprint "🖥 Create qcow2 file for virt install"
LIBVIRT_IMAGE_PATH=/var/lib/libvirt/images/${IMAGE_KEY}-keyhash.qcow2
sudo qemu-img create -f qcow2 "${LIBVIRT_IMAGE_PATH}" 20G

greenprint "💿 Install ostree image via installer(ISO) on UEFI VM"
sudo virt-install  --name="${IMAGE_KEY}-fdosshkey"\
                   --disk path="${LIBVIRT_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:31 \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --cdrom "/var/lib/libvirt/images/${ISO_FILENAME}" \
                   --boot "${BOOT_ARGS}" \
                   --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Import ov from manufacture db into owner db
import_ov

# Start VM.
greenprint "💻 Start UEFI VM"
sudo virsh start "${IMAGE_KEY}-fdosshkey"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $PUB_KEY_GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

greenprint "Waiting for FDO user onboarding finished"
for _ in $(seq 0 60); do
    RESULTS=$(wait_for_fdo "$PUB_KEY_GUEST_ADDRESS")
    if [[ $RESULTS == 1 ]]; then
        echo "FDO user is ready to use! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

greenprint "🕹 Get ostree install commit value"
INSTALL_HASH=$(curl "${PROD_REPO_URL}/refs/heads/${OSTREE_REF}")

# Add instance IP address into /etc/ansible/hosts
tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${PUB_KEY_GUEST_ADDRESS}

[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${FDO_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ansible_become=yes 
ansible_become_method=sudo
EOF

# Test IoT/Edge OS
sudo podman run -v "$(pwd)":/work:z -v "${TEMPDIR}":/tmp:z --rm quay.io/rhel-edge/ansible-runner:latest ansible-playbook -v -i /tmp/inventory -e os_name=redhat -e ostree_commit="${INSTALL_HASH}" -e ostree_ref="${REF_PREFIX}:${OSTREE_REF}" -e fdo_credential="true" -e sysroot_ro="$SYSROOT_RO" check-ostree.yaml || RESULTS=0
check_result

# Clean up VM
greenprint "🧹 Clean up VM"
if [[ $(sudo virsh domstate "${IMAGE_KEY}-fdosshkey") == "running" ]]; then
    sudo virsh destroy "${IMAGE_KEY}-fdosshkey"
fi
sudo virsh undefine "${IMAGE_KEY}-fdosshkey" --nvram
sudo virsh vol-delete --pool images "$IMAGE_KEY-keyhash.qcow2"

# Remove simplified installer ISO file
sudo rm -rf "/var/lib/libvirt/images/${ISO_FILENAME}"

# Final success clean up
clean_up

exit 0
