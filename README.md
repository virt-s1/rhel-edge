# RHEL-Edge

RHEL-Edge help [documentation](HELP.md)
1
## RHEL-Edge Test Scope

RHEL for Edge test from QE is more like an integration test. The test flow aligns with the customer scenario. The whole test includes three parts:

1. RHEL for Edge image building with [osbuild-composer](https://github.com/osbuild/osbuild-composer.git)

    - Build RHEL 8 and RHEL 9 x86_64 images at OpenStack VM
    - Build CentOS Stream 8, CentOS Stream 9 and Fedora x86_64 images at Google Cloud VM
    - Build ARM images on bare metal ARM server or ARM VM at beaker

2. RHEL for Edge image installation

    - `edge-commit/iot-commit`: Setup HTTP server to serve as ostree repo, and HTTP boot to install with kickstart
    - `edge-container/iot-container`: Setup prod ostree repo, `edge-container/iot-container` as stage repo, and install with kickstart from prod ostree repo
    - `edge-installer/iot-installer`: Install from `edge-installer/iot-installer` ISO
    - `edge-raw-image/iot-raw-image`: Boot from raw image with KVM
    - `edge-simplified-installer`: Install from `edge-simplified-installer` ISO
    - `minimal-raw`: Boot from RPM based raw image with KVM
    - `edge-ami`: Image for AWS ec2 instance

3. RHEL for Edge system upgrade

    - Upgrade with the same OSTree ref
    - Rebase to a new OSTree ref
    - Upgrade from RHEL 8 to RHEL 9 or from CentOS Stream 8 to CentOS Stream 9

3. Checkings after installation/upgrade.

    - Check installed ostree commit
    - Check mount point
    - Check [`greenboot`](https://github.com/fedora-iot/greenboot.git) services
    - Run container with `podman` (root and non-root)
    - Check persistent journal log
    - Check FDO onboarding and status (simplified-installer only)
    - Check LVM PV and LV, and check growfs (raw-image and simplified-installer only)
    - Check auto rollback with [`greenboot`](https://github.com/fedora-iot/greenboot.git) when failure is detected
    - Check ignition configurations (raw-image and simplified-installer only)

## RHEL-Edge CI

### Upstream CI

For RHEL-Edge project, 90% of features come from [osbuild](https://github.com/osbuild/osbuild.git) and [osbuild-composer](https://github.com/osbuild/osbuild-composer.git). In this case, [osbuild](https://github.com/osbuild/osbuild.git) and [osbuild-composer](https://github.com/osbuild/osbuild-composer.git) CI will be used ad RHEL-Edge project upstream CI.

The Upstream CI is triggered by each PR and it focuses on code change.

Considering Upstream CI environment and test duration, the Upstream CI only covers virtualization tests, bare metal is out of Upstream CI scope.

### Downstream CI

[RHEL 8/9, CentOS Stream 8/9 report dashboard](https://github.com/virt-s1/rhel-edge/projects/1)

[Fedora report dashboard](https://github.com/virt-s1/rhel-edge/projects/2)

[Package greenboot, fido-device-onboard, rust-coreos-installer, rpm-ostree, ostree report](https://github.com/virt-s1/rhel-edge/projects/3)

[Customer case test report](https://github.com/virt-s1/rhel-edge/projects/4)

### CI for this repository

CI for this repository is to test `test code`. It's triggered by PR in this repository. Any changes for `test code` has to be pass all tests of CI before they are merged into master.

Test of this CI includes:

1. [commit lint](https://www.conventionalcommits.org/en/v1.0.0/)
2. [spell check](https://github.com/codespell-project/codespell)
3. [Shellcheck](https://www.shellcheck.net/): running on Github
4. [Yaml lint](https://yamllint.readthedocs.io/en/stable/): running on Github
5. [Edge tests](https://github.com/virt-s1/rhel-edge/blob/main/CI.md#rhel-for-edge-ci): running on Github

RHEL-Edge CI details can be found from [CI doc](CI.md)

## RHEL-Edge Test

### Test Scenario

Test suites in scenario:

1. [`ostree.sh`](ostree.sh) and [`arm-commit.sh`](arm-commit.sh): edge-commit/iot-commit(tar) image type test on RHEL 8.x, RHEL 9.x, CentOS Stream 8,  CentOS Stream 9, and Fedora
2. [`ostree-ng.sh`](ostree-ng.sh) and [`arm-installer.sh`](arm-installer.sh): edge-container/iot-container and edge-installer/iot-installer(ISO) image types test on RHEL 8.x, RHEL 9.x, CentOS Stream 8, CentOS Stream 9 and Fedora
3. [`ostree-raw-image.sh`](ostree-raw-image.sh) and [`arm-raw.sh`](arm-raw.sh): edge-raw-image/iot-raw-image(raw) image types test on RHEL 8.x, RHEL 9.x, CentOS Stream 8, CentOS Stream 9, and Fedora
4. [`ostree-simplified-installer.sh`](ostree-simplified-installer.sh) and [`arm-simplified.sh`](arm-simplified.sh): edge-simplified-installer(ISO) image types test on RHEL 8.x, RHEL 9.x, CentOS Stream 8, and CentOS Stream 9
5. [`arm-rebase.sh`](arm-rebase.sh): Different ostree ref rebase test on RHEL 8.x and CentOS Stream 8
6. [`ostree-8-to-9.sh`](ostree-8-to-9.sh): RHEL 8/CentOS Stream 8 Edge system upgrade to RHEL 9/CentOS Stream 9 Edge system test
6. [`ostree-9-to-9.sh`](ostree-9-to-9.sh): RHEL 9/CentOS Stream 9 Edge system upgrade and rebase to RHEL 9/CentOS Stream 9 Edge system test
7. [`minimal-raw.sh`](minimal-raw.sh) and [`arm-minimal.sh`](arm-minimal.sh): RPM based system test (Not ostree)
8. [`ostree-ignition.sh`](ostree-ignition.sh) and [`arm-ignition.sh`](arm-ignition.sh): Ignition test for simplified installer and raw image
8. [`ostree-ami-image.sh`](ostree-ami-image.sh): AWS ec2 instance image test

### Test environment

#### For x86_64

You can run RHEL for Edge test on any x86_64 machine, like server, laptop, or VM, but KVM has to be enabled. Otherwise QEMU will be used and the test will take a really long time.

    $ls -l /dev/kvm

#### for ARM

To run RHEL for Edge test on ARM server, a bare metal ARM server is required.

#### Supported OS

    RHEL 8.6/8.8/8.9
    RHEL 9.0/9.2/9.3
    CentOS Stream 8
    CentOS Stream 9
    Fedora 37 (Simplified-installer not supported)
    Fedora 38 (Simplified-installer not supported)
    Fedora rawhide (Simplified-installer not supported)

### Test Run

#### For x86_64

    $ DOWNLOAD_NODE="hello-world.com" ./ostree.sh
    $ DOWNLOAD_NODE="hello-world.com" OCP4_TOKEN=abcdefg QUAY_USERNAME=rhel-edge QUAY_PASSWORD=123456 ./ostree-ng.sh
    $ DOWNLOAD_NODE="hello-world.com" DOCKERHUB_USERNAME=rhel-edge DOCKERHUB_PASSWORD=123456 ./ostree-raw-image.sh
    $ DOWNLOAD_NODE="hello-world.com" ./ostree-simplified-installer.sh
    $ DOWNLOAD_NODE="hello-world.com" ./ostree-8-to-9.sh
    $ DOWNLOAD_NODE="hello-world.com" ./ostree-9-to-9.sh
    $ ./minimal-raw.sh (Fedora 37 and above)
    $ DOWNLOAD_NODE="hello-world.com" ./ostree-ignition.sh
    $ DOWNLOAD_NODE="hello-world.com" ./ostree-ami-image.sh

#### For ARM64

    $ tools/deploy_bare.sh
    $ DOWNLOAD_NODE="hello-world.com" ./arm-commit.sh <test os>
    $ DOWNLOAD_NODE="hello-world.com" QUAY_USERNAME=rhel-edge QUAY_PASSWORD=123456 ./arm-installer.sh <test os>
    $ DOWNLOAD_NODE="hello-world.com" DOCKERHUB_USERNAME=rhel-edge DOCKERHUB_PASSWORD=123456 ./arm-raw.sh <test os>
    $ DOWNLOAD_NODE="hello-world.com" ./arm-simplified.sh <test os>
    $ DOWNLOAD_NODE="hello-world.com" ./arm-ignition.sh <centos-stream-9 or rhel-9-2>
    $ DOWNLOAD_NODE="hello-world.com" ./arm-minimal.sh <fedora-37 or fedora-38>

    <test os> can be one of "rhel-9-3", "centos-stream-9", "fedora-38"

### Test Configuration

You can set these environment variables to run test

    QUAY_USERNAME      quay.io username
                           Used to test pushing Edge OCI-archive image to quay.io
    QUAY_PASSWORD      quay.io password
                           Used to test pushing Edge OCI-archive image to quay.io
    DOCKERHUB_USERNAME      Docker hub account username
                           Used to test pushing Edge OCI-archive image to Docker hub
    DOCKERHUB_PASSWORD      Docker hub account password
                           Used to test pushing Edge OCI-archive image to Docker hub
    OCP4_TOKEN         Edit-able SA token on PSI Openshift 4
                           Deploy edge-container on PSI OCP4
    DOWNLOAD_NODE      RHEL nightly compose download URL

## Contact us

- RHEL for Edge discussion channel: [`Google Chat room`](https://mail.google.com/chat/u/0/#chat/space/AAAAlhJ-myk)
