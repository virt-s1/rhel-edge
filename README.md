# RHEL-Edge Test

RHEL-Edge help [documentation](HELP.md)

## RHEL-Edge Test Scope

RHEL for Edge test from QE is more like an integration test. The test flow aligns with the customer scenario. The whole test includes three parts:

1. RHEL for Edge image building with [osbuild-composer](https://github.com/osbuild/osbuild-composer.git)

    - Build RHEL 8 and RHEL 9 x86_64 images at OpenStack VM
    - Build CentOS Stream 8 and CentOS Stream 9 x86_64 images at Google Cloud VM

2. RHEL for Edge image installation and upgrade

    - `edge-commit`: Setup HTTP server to serve as ostree repo, and install with kickstart
    - `edge-container`: Setup prod ostree repo, `edge-container` as stage repo, and install with kickstart from prod ostree repo
    - `edge-installer`: Install from `edge-installer` ISO
    - `edge-raw-image`: Boot from raw image with KVM
    - `edge-simplified-installer`: Install from `edge-simplified-installer` ISO

3. checkings after installation/upgrade.

    - Check installed ostree commit
    - Check mount point
    - Check [`greenboot`](https://github.com/fedora-iot/greenboot.git) services
    - Check auto rollback with [`greenboot`](https://github.com/fedora-iot/greenboot.git) when failure is detected

4. RHEL for Edge rebase

    - Build upgrade ostree commit with different ostree ref
    - Rebase on new ostree ref

5. RHEL for Edge system upgrade test

    - From RHEL 8 to RHEL 9
    - From CentOS Stream 8 to CentOS Stream 9

## RHEL-Edge CI

### Upstream CI

For RHEL-Edge project, 90% of features come from [osbuild](https://github.com/osbuild/osbuild.git) and [osbuild-composer](https://github.com/osbuild/osbuild-composer.git). In this case, [osbuild](https://github.com/osbuild/osbuild.git) and [osbuild-composer](https://github.com/osbuild/osbuild-composer.git) CI will be used ad RHEL-Edge project upstream CI.

The Upstream CI is triggered by each PR and it focuses on code change.

Considering Upstream CI environment and test duration, the Upstream CI only covers virtualization tests, bare metal is out of Upstream CI scope.

### Downstream CI

[RHEL 8, RHEL 9, CentOS Stream 8 and CentOS Stream 9 report dashboard](https://github.com/virt-s1/rhel-edge/projects/1)

[Fedora rawhide report dashboard](https://github.com/virt-s1/rhel-edge/projects/2)

### CI for this repository

CI for this repository is to test `test code`. It's triggered by PR in this repository. Any changes for `test code` has to be pass all tests of CI before they are merged into master.

Test of this CI includes:

1. [Shellcheck](https://www.shellcheck.net/): running as Github Action
2. [Yaml lint](https://yamllint.readthedocs.io/en/stable/): running as Github Action
3. [Edge tests](https://github.com/virt-s1/rhel-edge/blob/main/CI.md#rhel-for-edge-ci): running as Github Action

### Test Scenario

Test suites in scenario:

1. [`ostree.sh`](ostree.sh): rhel-edge-commit/edge-commit(tar) image type test on RHEL 8.x, RHEL 9.x, CentOS Stream 8, and CentOS Stream 9
2. [`ostree-ng.sh`](ostree-ng.sh): rhel-edge-container/edge-container(tar) and rhel-edge-installer/edge-installer(ISO) image types test on RHEL 8.x, RHEL 9.x, CentOS Stream 8, and CentOS Stream 9
3. [`ostree-raw-image.sh`](ostree-raw-image.sh): edge-raw-image image types test on RHEL 8.x, RHEL 9.x, CentOS Stream 8, and CentOS Stream 9
4. [`ostree-simplified-installer.sh`](ostree-simplified-installer.sh): edge-simplified-installer image types test on RHEL 8.x, RHEL 9.x, CentOS Stream 8, and CentOS Stream 9
5. [`ostree-rebase.sh`](ostree-rebase.sh): Different ostree ref rebase test
6. [`ostree-8-to-9.sh`](ostree-8-to-9.sh): RHEL 8/CentOS Stream 8 Edge system upgrade to RHEL 9/CentOS Stream 9 Edge system test

#### Test environment prpare

1. You can run this scenario on any RHEL machine, like server, laptop, or VM, but KVM has to be enabled.

        $ls -l /dev/kvm

2. Required packages.

    - ansible
    - jq
    - qemu-img
    - qemu-kvm
    - libvirt-client
    - libvirt-daemon-kvm
    - virt-install

## Run Test

    $ ./ostree.sh
    $ OCP4_TOKEN=abcdefg QUAY_USERNAME=rhel-edge QUAY_PASSWORD=123456 ./ostree-ng.sh
    $ ./ostree-raw-image.sh
    $ ./ostree-simplified-installer.sh
    $ ./ostree-rebase.sh
    $ ./ostree-8-to-9.sh

## Configuration

You can set these environment variables to run test

    TEST_OS            The OS to run the tests in.  Currently supported values:
                           "rhel-8-6"
                           "rhel-8-7"
                           "rhel-9-0"
                           "rhel-9-1"
                           "centos-stream-8"
                           "centos-stream-9"
    ARCH               The arch to build image and run test on.  Currently supported values:
                           "x86_64"
    QUAY_USERNAME      quay.io username
                           Used to test pushing Edge OCI-archive image to quay.io
    QUAY_PASSWORD      quay.io password
                           Used to test pushing Edge OCI-archive image to quay.io
    OCP4_TOKEN         Edit-able SA token on PSI Openshift 4
                           Deploy edge-container on PSI OCP4

## Contact us

- RHEL for Edge discussion channel: [`Google Chat room`](https://mail.google.com/chat/u/0/#chat/space/AAAAlhJ-myk)
