# RHEL-Edge Test

## Test Scenarios

1. Build RHEL Edge image on Openstack VM and install it on nested VM.
2. Build RHEL Edge image on OpenStack VM and install it on bare metal machine.

## Requirement

This framework is `ansible` based. `ansible` has to be installed in machine to run ansible playbook.

### Scenario 1

1. You can run this scenario on any RHEL machine, like server, laptop, or VM, but KVM has to be enabled.

        $ls -l /dev/kvm

2. Required packages.

    - ansible
    - jq
    - expect
    - qemu-img
    - qemu-kvm
    - libvirt-client
    - libvirt-daemon-kvm
    - virt-install
    - python3-lxml

### Scenario 2

1. The test runs on beaker because test needs bare metal machine. So keytab file is needed for beaker authentication.
2. The RHEL Edge image will be built on OpenStack VM, the encrypted OpenStack credential should be provided.

## Run Test

### Scenario 1

    $ARCH=x86_64 TEST_OS=rhel-8-4 ./rhel-edge-virt-test.sh

### Scenario 2

    $ARCH=x86_64 TEST_OS=rhel-8-4 ansible-playbook -v -i inventory ostree-bare.yml

## Configuration

You can set these environment variables to configure to run test

    TEST_OS        The OS to run the tests in.  Currently supported values:
                       "rhel-8-3"
                       "rhel-8-4"
    ARCH           The arch to build image and run test on.  Currently supported values:
                       "x86_64"
