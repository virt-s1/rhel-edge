# AGENTS.md

This is an integration test repository for RHEL for Edge and Fedora IoT, not a product codebase.
It builds and validates OSTree-based and bootc-based Edge images (RHEL, CentOS Stream, Fedora) and IoT images (Fedora IoT), all on x86_64 and aarch64 architectures.
Tests run on VMs provisioned by Testing Farm, triggered by GitHub Actions.

## Project structure

```
*.sh                      Test scripts. Each script is an integration test for one image type.
setup.sh                  Environment provisioning for Edge tests — installs the osbuild-composer
                          package, sets up osbuild-composer repository sources from files/,
                          starts services (httpd, osbuild-composer, firewalld, libvirtd).
                          Designed for disposable VMs, not development machines.
iot-setup.sh              Environment provisioning for IoT tests (used instead of setup.sh).
                          Designed for disposable VMs, not development machines.
tmt/
  plans/edge-test.fmf     Edge test plan definitions (FMF format). Each plan sets a TEST_CASE env var.
  plans/iot-test.fmf      IoT test plan definitions (FMF format). Each plan sets a TEST_CASE env var.
  tests/test.sh           Dispatcher — maps TEST_CASE value to the corresponding root-level test script.
  tests/*.fmf             Test metadata (duration, test script reference).
.github/workflows/        GitHub Actions workflows:
  lint.yml                PR linting (commitlint, codespell, shellcheck, yamllint). Runs on every PR.
  trigger-*.yml           Compose detection — each runs daily, creates PRs for new composes.
  rhel-*.yml, centos-*.yml, fedora-*.yml, fdo-container.yml
                          Test execution — triggered by /test-* PR comments, calls Testing Farm.
  cleanup-*.yaml          Periodic cleanup of AWS and vSphere resources.
  clear-compose-file.yml  Periodic cleanup of compose tracking files.
files/                    osbuild-composer repository JSON configs, one per distro version.
  fdo/                    FDO server configuration files (used by FDO test scripts).
compose/                  Compose ID tracking files. Managed by trigger-*.yml workflows,
                          do not edit manually.
tools/                    Cloud resource cleanup utilities (used by CI workflows) and
                          ARM/edge-raw test scripts (not referenced from CI).
key/                      SSH keys for guest VM access during testing. Do not modify.
check-ostree*.yaml        Ansible playbooks for post-installation system validation.
```

### Test case to script mapping

The dispatcher `tmt/tests/test.sh` routes `TEST_CASE` values to scripts:

| `TEST_CASE`                  | Script                            |
|------------------------------|-----------------------------------|
| `edge-commit`                | `ostree.sh`                       |
| `edge-installer`             | `ostree-ng.sh`                    |
| `edge-raw-image`             | `ostree-raw-image.sh`             |
| `edge-ami-image`             | `ostree-ami-image.sh`             |
| `edge-simplified-installer`  | `ostree-simplified-installer.sh`  |
| `edge-vsphere`               | `ostree-vsphere.sh`               |
| `edge-fdo-aio`               | `ostree-fdo-aio.sh`               |
| `edge-fdo-db`                | `ostree-fdo-db.sh`                |
| `edge-ignition`              | `ostree-ignition.sh`              |
| `edge-pulp`                  | `ostree-pulp.sh`                  |
| `edge-8to9`                  | `ostree-8-to-9.sh`                |
| `edge-9to9`                  | `ostree-9-to-9.sh`                |
| `edge-fdo-container`         | `ostree-fdo-container.sh`         |
| `iot-installer`              | `iot-installer.sh`                |
| `iot-simplified-installer`   | `iot-simplified-installer.sh`     |
| `iot-raw-image`              | `iot-raw-image.sh`                |
| `iot-bootc`                  | `iot-bootc-image.sh`              |

## Test instructions

### Linting (defined in `lint.yml`, runs on every PR)

Local equivalents (`commitlint` runs only in CI):

```
codespell --check-filenames --ignore-words-list bu
shellcheck -e SC1091 -e SC2002 -e SC2317 -e SC2329 *.sh
yamllint .
```

### Running tests locally

Tests require 16+ GB RAM, 60+ GB disk, 4+ CPUs for Edge / 2+ CPUs for IoT
(see `tmt/plans/*.fmf`). x86_64 tests require KVM; ARM tests require a bare metal ARM server.
Each Edge test script runs `./setup.sh` and each IoT test script runs `./iot-setup.sh`
internally, which installs packages and starts services.

```
DOWNLOAD_NODE="<compose-server>" ./ostree.sh
```

Some tests require additional environment variables set locally:
`QUAY_USERNAME`, `QUAY_PASSWORD`, `DOCKERHUB_USERNAME`,
`DOCKERHUB_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`GOVC_URL`, `GOVC_USERNAME`, `GOVC_PASSWORD`, `FDO_REGISTRY`
(see [`README.md`](README.md), section "Test Configuration").

Edge tests take up to 5 hours, IoT tests up to 90 minutes.

### Triggering CI tests

Add a PR comment to trigger tests on Testing Farm. Each trigger runs the
same set of test cases (filtered by FMF `adjust` rules per distro):

| Pattern               | Example          |
|-----------------------|------------------|
| `/test-rhel-<X>-<Y>`  | `/test-rhel-9-6` |
| `/test-cs<X>`          | `/test-cs9`      |
| `/test-f<XX>`          | `/test-f43`      |
| `/test-f<XX>-iot`      | `/test-f43-iot`  |

FDO container tests have separate triggers: `/test-fdo-container-community`,
`/test-fdo-container-official`.

Full trigger-to-script mapping is in [`CI.md`](CI.md), section "How to run compose test manually".

### CI workflow

Compose detection (trigger workflows, daily) → auto-created PR with compose ID →
`/test-*` comment → GitHub Actions calls Testing Farm → Testing Farm provisions VM,
runs TMT plan → TMT sets `TEST_CASE` and executes test script → results posted to
Slack and PR status.

## Coding conventions

- Most shell scripts start with `set -exuo pipefail` (or `set -euox pipefail`).
  A few (`iot-setup.sh`, `ostree-vsphere.sh`) use `set -euo pipefail` without trace output.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (enforced by `commitlint` in CI). Examples: `fix: correct fallback log message`,
  `feat(ci): add retry to Slack notification`.
- All shell scripts must pass `shellcheck` with exclusions: `SC1091`, `SC2002`, `SC2317`, `SC2329`.
- YAML files follow `.yamllint.yml` rules.
- Test scripts follow a consistent internal pattern:
  setup → configure variables per distro → obtain image (Edge: build with `composer-cli`,
  IoT: download pre-built compose image) → deploy (`virt-install` / AWS / vSphere) →
  SSH into guest and run validation checks → cleanup.
- Edge scripts use the `greenprint` function for colored log output, IoT scripts
  use `log_info`/`log_error`. Both are defined locally in individual scripts,
  not imported from a shared location.
- SSH key permissions for `key/ostree_key` must be 600.

## Permissions

- **Always allowed**: read any file, run linting commands, search GitHub issues and PRs, analyze logs.
- **Ask first**: modify any file or configuration.
- **Never**: push directly to main, modify the `key/` directory, commit credentials or secrets.
