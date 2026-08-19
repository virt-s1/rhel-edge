# RHEL for Edge

This repository contains integration tests for two components:

- **RHEL for Edge** — RHEL, CentOS Stream, and Fedora Edge images built via `osbuild-composer`
- **Fedora IoT** — Fedora IoT images from pre-built compose artifacts

Tests run on x86_64 and aarch64 architectures, triggered by GitHub Actions and executed via Testing Farm.

## Table of contents

- [Test scope](#test-scope)
- [CI overview](#ci-overview)
- [Running tests](#running-tests)
  - [Test scenario](#test-scenario)
  - [Test environment](#test-environment)
  - [Test configuration](#test-configuration)
  - [Test run](#test-run)
- [Contact us](#contact-us)

## Test scope

The test flow covers the full lifecycle from image build to post-deployment validation. It includes four parts:

1. Image provisioning

    Edge tests - build images via [`osbuild-composer`](https://github.com/osbuild/osbuild-composer.git):

    - `edge-commit`: OSTree repository tarball
    - `edge-container`: OCI container with OSTree repository
    - `edge-installer`: Bootable ISO with embedded OSTree commit
    - `edge-raw-image`: Raw disk image, converted to `qcow2`
    - `edge-simplified-installer`: Bootable ISO with embedded OSTree commit
    - `edge-ami`: Raw disk image for AWS
    - `edge-vsphere`: VMDK image

    > Build RHEL, CentOS Stream, and Fedora x86_64 images on Testing Farm VMs.
    > Build ARM images on bare metal ARM server or ARM VM at beaker.

    Fedora IoT tests - download pre-built compose artifacts from [Koji](https://kojipkgs.fedoraproject.org/compose/iot/):

    - Installer ISO
    - Simplified installer ISO
    - Raw disk image, converted to `qcow2`
    - Bootc OCI image, converted to `qcow2`

2. Image installation and deployment

    - Edge: ISO boot, network boot (PXE), HTTP boot, VM disk image import, AWS EC2, vSphere
    - IoT: ISO boot, VM disk image import

3. System upgrade (Edge only)

    - Upgrade with the same OSTree ref
    - Rebase to a new OSTree ref
    - Upgrade from RHEL 8 to RHEL 9

4. Post-deployment validation

    Edge checks ([`check-ostree.yaml`](check-ostree.yaml)):

    - Check BIOS/UEFI and secure boot status
    - Check `SELinux` status and enforcing mode
    - Check root password status (locked)
    - Check installed `ostree` commit and ref
    - Check `ostree-remount` service status
    - Check mount points (`/sysroot`, `/var`, `/usr`, `/boot`)
    - Check LVM PV and LV, and check `growfs` (`raw-image` and `simplified-installer` only)
    - Check [`greenboot`](https://github.com/fedora-iot/greenboot-rs.git) services
    - Check auto rollback with [`greenboot`](https://github.com/fedora-iot/greenboot-rs.git) when failure is detected
    - Run container with `podman` (root and non-root)
    - Check embedded container images
    - Check persistent journal log
    - Check `dmesg` error and fail log
    - Check `Ignition` configurations (`raw-image` and `simplified-installer` only)
    - Check FDO onboarding, status, and re-encryption (`simplified-installer` only)
    - Check firewall customizations
    - Check installed packages (`wget`, `sos`)
    - Check custom files, directories, and services
    - Check `systemd` failed units

    IoT checks ([`check-ostree-iot.yaml`](check-ostree-iot.yaml)):

    - Check BIOS/UEFI status
    - Check `SELinux` status and enforcing mode
    - Check secure boot and TPM device
    - Check partition layout and disk table
    - Check `rpm-ostree` status
    - Check `ostree` ref and deployment
    - Check `ostree-remount` service status
    - Check mount points (`/sysroot` `ro`, `/var` `rw`)
    - Check FDO onboarding (`simplified-installer` only)
    - Check [`greenboot`](https://github.com/fedora-iot/greenboot-rs.git) and rollback
    - Check `boot-complete.target` status
    - Check `grubenv` variables (`boot_success`)
    - Run container with `podman` (root and non-root)
    - Check `systemd` failed units

## CI overview

### Upstream CI

For RHEL for Edge project, 90% of features come from [`osbuild`](https://github.com/osbuild/osbuild.git) and [`osbuild-composer`](https://github.com/osbuild/osbuild-composer.git). In this case, [`osbuild`](https://github.com/osbuild/osbuild.git) and [`osbuild-composer`](https://github.com/osbuild/osbuild-composer.git) CI will be used as RHEL for Edge project upstream CI.

The upstream CI is triggered by each PR and it focuses on code change.

Considering upstream CI environment and test duration, the upstream CI only covers virtualization tests, bare metal is out of upstream CI scope.

### Repository CI

Lint checks run automatically on every pull request and must pass before merging into `main`:

1. [`commitlint`](https://www.conventionalcommits.org/en/v1.0.0/)
2. [`codespell`](https://github.com/codespell-project/codespell)
3. [`shellcheck`](https://www.shellcheck.net/)
4. [`yamllint`](https://yamllint.readthedocs.io/en/stable/)

Edge and IoT tests are triggered manually via `/test-*` PR comments and should pass before merging into `main` (see [CI doc](CI.md)).

## Running tests

### Test scenario

Edge tests:

| Script | Image type | Description |
|--------|-----------|-------------|
| [`ostree.sh`](ostree.sh) | `edge-commit` (tar) | OSTree commit deployed via kickstart |
| [`ostree-ng.sh`](ostree-ng.sh) | `edge-installer` (ISO) | OSTree commit deployed via ISO installer |
| [`ostree-raw-image.sh`](ostree-raw-image.sh) | `edge-raw-image` (raw) | Raw disk image deployed via VM import |
| [`ostree-simplified-installer.sh`](ostree-simplified-installer.sh) | `edge-simplified-installer` (ISO) | OSTree commit deployed via simplified ISO installer |
| [`ostree-fdo-aio.sh`](ostree-fdo-aio.sh) | `edge-simplified-installer` (ISO) | FDO onboarding with all-in-one server |
| [`ostree-fdo-db.sh`](ostree-fdo-db.sh) | `edge-simplified-installer` (ISO) | FDO onboarding with database-backed servers |
| [`ostree-fdo-container.sh`](ostree-fdo-container.sh) | `edge-simplified-installer` (ISO) | FDO onboarding with containerized servers |
| [`ostree-ignition.sh`](ostree-ignition.sh) | `edge-simplified-installer` + `edge-raw-image` | Ignition provisioning on simplified installer ISO and raw disk image |
| [`ostree-pulp.sh`](ostree-pulp.sh) | `edge-commit` (tar) | OSTree commit distributed via Pulp server |
| [`ostree-vsphere.sh`](ostree-vsphere.sh) | `edge-vsphere` (VMDK) | VMDK image deployed to vSphere |
| [`ostree-ami-image.sh`](ostree-ami-image.sh) | `edge-ami` (raw) | AMI deployed to AWS EC2 |
| [`ostree-8-to-9.sh`](ostree-8-to-9.sh) | `edge-container` (OCI) | Upgrade from RHEL 8 / CS8 to RHEL 9 / CS9 |
| [`ostree-9-to-9.sh`](ostree-9-to-9.sh) | `edge-container` (OCI) | Upgrade within RHEL 9 |

Fedora IoT tests:

| Script | Image type | Description |
|--------|-----------|-------------|
| [`iot-installer.sh`](iot-installer.sh) | IoT installer ISO | Fedora IoT installer ISO deployed via kickstart |
| [`iot-raw-image.sh`](iot-raw-image.sh) | IoT raw disk image | Fedora IoT raw disk image deployed via VM import |
| [`iot-simplified-installer.sh`](iot-simplified-installer.sh) | IoT simplified installer ISO | Fedora IoT simplified installer ISO with FDO and Ignition |
| [`iot-bootc-image.sh`](iot-bootc-image.sh) | IoT `bootc` OCI image | Fedora IoT `bootc` image built via `bootc-image-builder` |

### Test environment

#### For x86_64

Tests can run on any x86_64 machine (server, laptop, or VM), but KVM must be enabled. Without KVM, QEMU will be used and tests will take a really long time.

Verify that KVM is available:

    $ ls -l /dev/kvm

#### For aarch64

To run tests on ARM, a bare metal ARM server is required.

#### Supported OS

- RHEL 8.10
- RHEL 9.4/9.5/9.6
- CentOS Stream 9
- Fedora IoT 44
- Fedora IoT 45

### Test configuration

Environment variables used by test scripts and CI workflows. Most test scripts require no environment variables.

| Environment variable | Used by | Purpose |
|-------------|---------|---------|
| `DOWNLOAD_NODE` | `ostree.sh`, `ostree-pulp.sh`, `ostree-8-to-9.sh`, `ostree-9-to-9.sh`, `setup.sh`, `tools/arm-*.sh` | RHEL nightly compose download URL |
| `QUAY_USERNAME` | `ostree-ng.sh`, `tools/arm-installer.sh` | quay.io username for pushing OCI images |
| `QUAY_PASSWORD` | `ostree-ng.sh`, `tools/arm-installer.sh` | quay.io password for pushing OCI images |
| `DOCKERHUB_USERNAME` | `tools/arm-raw.sh`, `tools/edge-raw.sh`, CI workflows | Docker Hub username for pushing OCI images |
| `DOCKERHUB_PASSWORD` | `tools/arm-raw.sh`, `tools/edge-raw.sh`, CI workflows | Docker Hub password for pushing OCI images |
| `AWS_ACCESS_KEY_ID` | AMI tests (via `aws` CLI) | AWS credentials for AMI upload and EC2 |
| `AWS_SECRET_ACCESS_KEY` | AMI tests (via `aws` CLI) | AWS credentials for AMI upload and EC2 |
| `AWS_DEFAULT_REGION` | AMI tests (via `aws` CLI) | AWS region (default: `us-east-1`) |
| `GOVC_URL` | vSphere CI workflows | vSphere server URL |
| `GOVC_USERNAME` | vSphere CI workflows | vSphere username |
| `GOVC_PASSWORD` | vSphere CI workflows | vSphere password |

### Test run

#### For x86_64

    $ DOWNLOAD_NODE="hello-world.com" ./ostree.sh
    $ QUAY_USERNAME=rhel-edge QUAY_PASSWORD=123456 ./ostree-ng.sh
    $ ./iot-installer.sh

#### For aarch64
> **Note:** The aarch64 commands listed below have not been recently tested and may not work as expected. There is currently no capacity to verify them.

    $ DOWNLOAD_NODE="hello-world.com" QUAY_USERNAME=rhel-edge QUAY_PASSWORD=123456 ./tools/arm-installer.sh <test os>
    $ DOWNLOAD_NODE="hello-world.com" DOCKERHUB_USERNAME=rhel-edge DOCKERHUB_PASSWORD=123456 ./tools/arm-raw.sh <test os>

    <test os> can be, for example, "rhel-9-6" or "centos-stream-9"

## Contact us

Please open a [GitHub issue](https://github.com/virt-s1/rhel-edge/issues) or start a [GitHub discussion](https://github.com/virt-s1/rhel-edge/discussions).
