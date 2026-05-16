# AGENTS.md

This is an integration test repository for RHEL for Edge and Fedora IoT, not a product codebase.
It validates OSTree-based Edge images (RHEL, CentOS Stream, Fedora) and IoT images (Fedora IoT, including `bootc`), all on x86_64 and aarch64 architectures.
Edge tests build images via `composer-cli`; IoT tests download pre-built compose images.
Tests run on VMs provisioned by Testing Farm, triggered by GitHub Actions.

For test scope, test scenarios, environment, configuration, and running tests see [`README.md`](README.md).
For CI trigger patterns, manual testing, and linting details see [`CI.md`](CI.md).

## Agent workflow guidelines

- For non-trivial changes, propose a short plan and ask for review before implementing.
- Never assume or guess intent. If instructions, code, or documentation are ambiguous, ask for clarification.
- If you find a potential bug or security issue, inform the developer before proceeding.
- Run `shellcheck` and `codespell` on changed files before proposing a commit.
- Follow existing patterns in the codebase — scripts are self-contained, not modularized into shared libraries.
- Test scripts run on disposable VMs — do not add defensive guards for local development environments.
- All changes must be reviewed and approved by a human before they can be committed.
  All commits should be signed off by a human contributor.
- AI-assisted contributions must include an `Assisted-by` trailer:
  `Assisted-by: AGENT_NAME (MODEL_VERSION)`.

## Project structure

```
*.sh                      Test scripts. Each script is an integration test for one image type.
setup.sh                  Environment provisioning — called internally by each Edge test script
                          (not a standalone tool). Designed for disposable VMs.
iot-setup.sh              Environment provisioning — called internally by each IoT test script
                          (not a standalone tool). Designed for disposable VMs.
tmt/
  plans/edge-test.fmf     Edge test plan definitions (FMF format). Each plan sets a TEST_CASE env var.
  plans/iot-test.fmf      IoT test plan definitions (FMF format). Each plan sets a TEST_CASE env var.
  tests/test.sh           Dispatcher — TMT calls it with TEST_CASE env var, it routes to the
                          corresponding root-level test script (see mapping table below).
  tests/*.fmf             Test metadata (duration, test script reference).
.github/workflows/        GitHub Actions workflows:
  lint.yml                PR linting (commitlint, codespell, shellcheck, yamllint). Runs on every PR.
  trigger-*.yml           Compose detection — each runs daily, creates PRs for new composes.
  rhel-*.yml, centos-*.yml, fedora-*.yml, fdo-container.yml
                          Test execution — triggered by /test-* PR comments, calls Testing Farm.
  cleanup-*.yaml          Periodic cleanup of AWS and vSphere resources.
  clear-compose-file.yml  Periodic cleanup of compose tracking files.
files/                    osbuild-composer repository JSON configs, one per distro version.
                          Consumed by setup.sh during provisioning.
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

Keep this table in sync with `tmt/tests/test.sh`.

## CI workflow

1. Compose detection (daily `trigger-*.yml`) → auto-created PR with compose ID as title.
2. `/test-*` comment → GitHub Actions calls Testing Farm.
3. Testing Farm provisions VM, runs TMT plan.
4. TMT sets `TEST_CASE` and executes test script.
5. Results posted to Slack and PR status.

## Coding conventions

See [`CONTRIBUTING.md`](CONTRIBUTING.md#coding-conventions) for full conventions.
Linting details in [`CI.md`](CI.md#rhel-edge-repository-ci).

Key points for agents:
- `set -exuo pipefail`
- `shellcheck` exclusions `SC1091 SC2002 SC2317 SC2329`
- commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)

## Permissions

- **Always allowed**: read any file, run linting commands, search GitHub issues and PRs, analyze logs.
- **Safe to change**: log messages, comments, variable names, documentation, test assertions,
  `codespell`/`yamllint` config.
- **Ask first**: anything that affects image building, test selection, or provisioning.
  This includes: blueprint definitions, `composer-cli` commands, `virt-install` parameters,
  kickstart templates, workflow files, FMF plans, test dispatcher,
  repository configs (`files/*.json`), provisioning scripts (`setup.sh`, `iot-setup.sh`),
  Ansible playbooks (`check-ostree*.yaml`).
- **Never**: push directly to `main`, modify `compose/` files (managed by CI), modify the `key/`
  directory, log, print, commit, or hardcode security-sensitive information
  (credentials, secrets).
