#!/bin/bash
set -euox pipefail

cd ../../ || exit 1

function run_tests() {
	if [ "$TEST_CASE" = "edge-commit" ]; then
		./ostree.sh
	elif [ "$TEST_CASE" = "edge-installer" ]; then
		./ostree-ng.sh
	elif [ "$TEST_CASE" = "edge-raw-image" ]; then
		./ostree-raw-image.sh
	elif [ "$TEST_CASE" = "edge-ami-image" ]; then
		./ostree-ami-image.sh
	elif [ "$TEST_CASE" = "edge-simplified-installer" ]; then
		./ostree-simplified-installer.sh
	elif [ "$TEST_CASE" = "edge-vsphere" ]; then
		./ostree-vsphere.sh
	elif [ "$TEST_CASE" = "edge-fdo-aio" ]; then
		./ostree-fdo-aio.sh
	elif [ "$TEST_CASE" = "edge-fdo-db" ]; then
		./ostree-fdo-db.sh
	elif [ "$TEST_CASE" = "edge-ignition" ]; then
		./ostree-ignition.sh
	elif [ "$TEST_CASE" = "edge-pulp" ]; then
		./ostree-pulp.sh
	elif [ "$TEST_CASE" = "edge-minimal" ]; then
		./minimal-raw.sh
	elif [ "$TEST_CASE" = "edge-8to9" ]; then
		./ostree-8-to-9.sh
	elif [ "$TEST_CASE" = "edge-9to9" ]; then
		./ostree-9-to-9.sh
	else
		echo "Error: Test case $TEST_CASE not found!"
		exit 1
	fi
}

run_tests
exit 0
