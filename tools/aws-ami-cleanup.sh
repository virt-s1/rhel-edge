#!/bin/bash
# Ignore Shellcheck error SC2016:
# Expressions don't expand in single quotes, use double quotes for that.
# This error appears due to the single quotes in "--query" option of
# awscli commands
# shellcheck disable=SC2016
set -euox pipefail

# Set up variables.
# Maximum idle timeout in hours
IDLE_TO=4
UPSTREAM_PREFIX_NAME="composer-ci-"
DOWNSTREAM_PREFIX_NAME="rhel-edge-"
BUCKET_LIST=bucket_list.json
SNAPSHOT_LIST=snapshot_list.json
IMAGES_LIST=images_list.json
KEYPAIR_LIST=keypair_list.json
INSTANCES_LIST=instances_list.json
UPSTREAM_TAG="rhel-edge-ci"
DOWNSTREAM_TAG="composer-ci"

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Calculate how old is the resource
time_subtraction () {
    current_time=$(date +%s)
    creation_time=$1
    
    hours_old_float=$(
        echo "${current_time}" \
            "$(date -d "${creation_time}" +%s)" \
            | awk '{print ($1 - $2) / 3600}'
    )
    hours_old_int=$(printf "%.0f\n" "${hours_old_float}")
    if [[ "${hours_old_int}" -ge "${IDLE_TO}" ]]; then
        echo 1
    else
        echo 0
    fi
}

greenprint "🧼 Cleaning up AWS resources in region ${AWS_DEFAULT_REGION}"

# List Upstream and Downstream AWS EC2 instances
greenprint "Checking AWS EC2 Idle Instances 🖥️"
aws ec2 describe-instances \
    --filters Name=tag:Name,Values=${UPSTREAM_TAG},${DOWNSTREAM_TAG} \
    Name=instance-state-name,Values=running \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    | sed -r 's/[\t]+|[ ]+/\n/g' \
    > "${INSTANCES_LIST}" || :

if [[ -z $(cat "${INSTANCES_LIST}") ]]; then
    echo "No idle instances to remove"
else
    mapfile -t INSTANCE_ARRAY < "${INSTANCES_LIST}"
    for line in "${INSTANCE_ARRAY[@]}"; do
        CREATION_DATE=$(
            aws ec2 describe-instances \
                --instance-ids "${line}" \
                --output text \
                --query 'Reservations[*].Instances[*].LaunchTime'
        )
        INSTANCE_AGE=$(time_subtraction "${CREATION_DATE}")
        if [[ "${INSTANCE_AGE}" == 1 ]]; then
            echo "Removing idle instance ${line}"
            aws ec2 terminate-instances \
                --instance-ids "${line}"
            aws ec2 wait instance-terminated \
                --instance-ids "${line}"
        fi
    done
fi
rm "${INSTANCES_LIST}"

# List Upstream and Downstream Buckets
greenprint "Checking AWS S3 Idle Buckets 🪣"
aws s3 ls \
    | grep -e "${UPSTREAM_PREFIX_NAME}" \
    -e "${DOWNSTREAM_PREFIX_NAME}" \
    > "${BUCKET_LIST}" || :
if [[ -z $(cat "${BUCKET_LIST}") ]]; then
    echo "No buckets to remove"
else
    mapfile -t BUCKET_ARRAY < "${BUCKET_LIST}"
    rm "${BUCKET_LIST}"
    
    for line in "${BUCKET_ARRAY[@]}"; do
        CREATION_DATE=$(
            echo "${line}" \
                | awk -F " |" '{print ($1" "$2)}'
        )
        BUCKET_NAME=$(
            echo "${line}" \
                | awk -F " |" '{print ($3)}'
        )
        BUCKET_AGE=$(time_subtraction "${CREATION_DATE}")
        if [[ "${BUCKET_AGE}" == 1 ]]; then
           echo "Removing bucket ${line}"
           aws s3 rb "s3://${BUCKET_NAME}" --force > /dev/null
        fi
    done
fi

# List Registered Images
greenprint "Checking AWS EC2 Idle AMIs 💽"
aws ec2 describe-images \
    --owners self \
    --query 'Images[?(Tags[?Value == `composer-ci`].Value)]' \
    | jq -r '.[] | .ImageId' > "${IMAGES_LIST}"
aws ec2 describe-images \
    --owners self \
    --query 'Images[?(Tags[?Value == `rhel-edge-ci`].Value)]' \
    | jq -r '.[] | .ImageId' >> "${IMAGES_LIST}"
mapfile -t IMAGES_ARRAY < "${IMAGES_LIST}"
rm "${IMAGES_LIST}"

for line in "${IMAGES_ARRAY[@]}"; do
    CREATION_DATE=$(
        aws ec2 describe-images \
            --image-ids "${line}" \
            | jq -r '.Images[] | .CreationDate'
    )
    IMAGE_ID="${line}"
    IMAGE_AGE=$(time_subtraction "${CREATION_DATE}")
    if [[ "${IMAGE_AGE}" == 1 ]]; then
       echo "De-registering image ${CREATION_DATE} ${IMAGE_ID}"
       aws ec2 deregister-image --image-id "${IMAGE_ID}" || :
    fi
done

# List Snapshots
greenprint "Checking AWS EC2 Idle Snapshots 💾"
aws ec2 describe-snapshots \
    --owner-ids self \
    --query 'Snapshots[?(Tags[?Value == `composer-ci`].Value)]' \
    | jq -r '.[] | .SnapshotId' > "${SNAPSHOT_LIST}"
aws ec2 describe-snapshots \
    --owner-ids self \
    --query 'Snapshots[?(Tags[?Value == `rhel-edge-ci`].Value)]' \
    | jq -r '.[] | .SnapshotId' >> "${SNAPSHOT_LIST}"
mapfile -t SNAPSHOTID_ARRAY < "${SNAPSHOT_LIST}"
rm "${SNAPSHOT_LIST}"

for line in "${SNAPSHOTID_ARRAY[@]}"; do
    CREATION_DATE=$(
        aws ec2 describe-snapshots \
            --snapshot-ids "${line}" \
            | jq -r '.Snapshots[] | .StartTime'
    )
    SNAPSHOT_ID="${line}"
    SNAPSHOT_AGE=$(time_subtraction "${CREATION_DATE}")
    if [[ ${SNAPSHOT_AGE} == 1 ]]; then
       echo "Removing snapshot ${CREATION_DATE} ${SNAPSHOT_ID}"
       aws ec2 delete-snapshot --snapshot-id "${SNAPSHOT_ID}" || :
    fi
done

# Clean idle key-pairs
greenprint "Checking AWS EC2 Idle key-pairs🔐"
aws ec2 describe-key-pairs \
    --query 'KeyPairs[?(Tags[?Value == `composer-ci`].Value)]' \
    | jq -r '.[] | .KeyName' > "${KEYPAIR_LIST}"
aws ec2 describe-key-pairs \
    --query 'KeyPairs[?(Tags[?Value == `rhel-edge-ci`].Value)]' \
    | jq -r '.[] | .KeyName' >> "${KEYPAIR_LIST}"
mapfile -t KEYPAIR_ARRAY < "${KEYPAIR_LIST}"
rm "${KEYPAIR_LIST}"

for line in "${KEYPAIR_ARRAY[@]}"; do
    CREATION_DATE=$(
        aws ec2 describe-key-pairs \
            --key-name "${line}" \
            | jq -r '.KeyPairs[] | .CreateTime'
    )
    KEYPAIR_NAME="${line}"
    KEYPAIR_AGE=$(time_subtraction "${CREATION_DATE}")
    if [[ ${KEYPAIR_AGE} == 1 ]]; then
       echo "Removing keypair ${CREATION_DATE} ${KEYPAIR_NAME}"
       aws ec2 delete-key-pair --key-name "${KEYPAIR_NAME}" || :
    fi
done

exit 0
