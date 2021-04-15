# RHEL-Edge Test

RHEL-Edge help [documentation](HELP.md)

## Test Scope

RHEL for Edge test from QE is more like an integration test. The test follow aligns with the customer scenario. The whole test includes three parts:

1. ostree image building
2. ostree image installation and upgrade
3. checkings after installation/upgrade.

This repository works with downstream CI which covers both virtualization and bare metal installation scenarios. Downstream CI is hosted by [Jenkins](https://jenkins-cloudci-prod-virt-qe-3rd.apps.ocp4.prod.psi.redhat.com/job/rhel-edge/job/rhel_edge_x86_64/) and triggered by RHEL nightly compose.

The test result will be sent to Google Chat Room [RHEL-Edge Nightly CI Bot](https://chat.google.com/u/0/room/AAAAvEUnS8s). If you're interested downstream RHEL for Edge test result, please join this room.

## Test Scenarios

1. Build RHEL Edge image on Openstack VM and install it on nested VM.
2. Build RHEL Edge image on OpenStack VM and install it on bare metal machine.

### Scenario 1

In this scenario, test code comes from [upstream](https://github.com/osbuild/osbuild-composer.git).

Two test suites in scenario 1:

1. `ostree.sh`: For rhel-edge-commit(tar) image type on both RHEL 8.3 and RHEL 8.4
1. `ostree-ng.sh`: For rhel-edge-container(tar) and rhel-edge-installer(ISO) image types on both RHEL 8.4 only

#### Test environment prpare

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

3. Clone upstream

        git clone -b rhel-8.4.0 https://github.com/osbuild/osbuild-composer.git

4. Setup required file

        sudo mkdir -p /usr/libexec/osbuild-composer-test && sudo cp files/provision.sh /usr/libexec/osbuild-composer-test/provision.sh

### Scenario 2

In this scenario, environment setup and test running are based on Ansible playbook. This scenario is for RHEL 8.4 only.

1. The test runs on beaker because test needs bare metal machine. So keytab file is needed for beaker authentication.
2. The RHEL Edge image will be built on OpenStack VM, the encrypted OpenStack credential should be provided.

#### Test environment prpare

1. Required packages.

    - ansible
    - python3-lxml

2. Environment.

    - OpenStack credentials
    - Kerberos keytab file for beaker

## Run Test

### Scenario 1

    osbuild-composer/test/cases/ostree.sh
    osbuild-composer/test/cases/ostree-ng.sh

### Scenario 2

    $ARCH=x86_64 TEST_OS=rhel-8-4 ansible-playbook -v -i inventory ostree-bare.yml

## Configuration

You can set these environment variables to configure to run test

    TEST_OS        The OS to run the tests in.  Currently supported values:
                       "rhel-8-3"
                       "rhel-8-4"
    ARCH           The arch to build image and run test on.  Currently supported values:
                       "x86_64"
