# RHEL for Edge CI

This document describes the CI pipelines for RHEL for Edge and Fedora IoT tests in this repository - automated compose triggers, manual test triggers, lint checks, and supporting workflows.

## RHEL compose CI

RHEL compose triggers run once a day for each supported RHEL version. They check the `COMPOSE_ID` of the latest compose. If the `COMPOSE_ID` can't be found in the corresponding compose file (e.g. `compose/compose.810`), a new pull request will be created, auto merge will be enabled, and a corresponding `/test-rhel-*` comment will be added. That will trigger all RHEL for Edge tests on the corresponding RHEL version VM deployed via Testing Farm.

## CentOS Stream compose CI

CentOS Stream compose trigger runs once a day. It checks the `COMPOSE_ID` of the latest compose. If the `COMPOSE_ID` can't be found in the compose file (e.g. `compose/compose.cs9`), a new pull request will be created, auto merge will be enabled, and a `/test-cs*` comment will be added. That will trigger all CentOS Stream Edge tests on a CentOS Stream VM deployed via Testing Farm.

## Fedora compose CI
> **Note:** This workflow is currently inactive.

Fedora compose trigger runs once a day. It checks the `COMPOSE_ID` of the latest compose. If the `COMPOSE_ID` can't be found in the compose file (e.g. `compose/compose.f43`), a new pull request will be created and a `/test-f*` comment will be added. That will trigger all Fedora Edge tests on a Fedora VM deployed via Testing Farm.

Fedora Rawhide compose trigger is currently disabled (commented out in `trigger-fedora.yml`). Tests can still be triggered manually with `/test-rawhide`.

## Fedora IoT compose CI

Fedora IoT compose triggers run daily for each supported Fedora IoT version (defined in `trigger-iot.yml`) and can also be run manually, for example, with `/test-f44-iot`. They check the `COMPOSE_ID` of the latest compose. If the `COMPOSE_ID` can't be found in the corresponding compose file (e.g. `compose/compose.f44-iot`), a new pull request will be created and a corresponding `/test-f*-iot` comment will be added. That will trigger all Fedora IoT tests on the corresponding Fedora IoT VM deployed via Testing Farm.

## How to run compose test manually

Create a pull request and add a comment according to the following table:

| Comment | Triggered tests |
|---------|-----------------|
| `/test-rhel-8-10` | All RHEL 8.10 Edge tests |
| `/test-rhel-9-4` | All RHEL 9.4 Edge tests |
| `/test-rhel-9-5` | All RHEL 9.5 Edge tests |
| `/test-rhel-9-6` | All RHEL 9.6 Edge tests |
| `/test-cs9` | All CentOS Stream 9 Edge tests |
| `/test-f44-iot` | Fedora IoT 44 tests |
| `/test-f45-iot` | Fedora IoT 45 tests |
| `/test-fdo-container-community` | FDO container community test |
| `/test-fdo-container-official` | FDO container official test |

## `rhel-edge` repository CI

Any pull request will trigger **Lint** job automatically. Edge tests will not be run by default. To run Edge test, add comment with content according to the table above.

Lint checks (defined in `.github/workflows/lint.yml`):

| Check | Local equivalent |
|-------|------------------|
| Commit messages | CI only (`commitlint`) |
| Spelling | `codespell --check-filenames --ignore-words-list bu` |
| Shell scripts | `find . -name '*.sh' -print0 \| xargs -0 shellcheck -e SC1091 -e SC2002 -e SC2317 -e SC2329` |
| YAML | `yamllint .` |

## FDO container CI

FDO container community test runs on Sundays, official test runs on Thursdays (defined in `trigger-fdo-container.yml`). The `latest` tag containers will be pulled.

## Other CI workflows

- **AWS AMI cleanup** (`cleanup-aws-ami.yaml`): removes stale AMI resources
- **vSphere cleanup** (`cleanup-vsphere.yaml`): removes stale vSphere resources
- **Compose file cleanup** (`clear-compose-file.yml`): clears compose files on schedule

## RHEL for Edge package CI
> **Note:** This workflow is currently inactive.

RHEL for Edge packages, like `ostree`, `rpm-ostree`, `greenboot`, `rust-coreos-installer`, `fido-device-onboard`, will be monitored by brew message on UMB. The message will be cached when package finished its building and the test will be run against new package.

## Customer case
> **Note:** This workflow is currently inactive.

Customer case related test will be run weekly for regression.
