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

## FDO compose CI

The FDO compose trigger (`trigger-fdo.yml`) runs weekly on Monday at 05:00 UTC and checks both RHEL 10.2 and RHEL 9.8.0 nightly composes. For each new compose (not found in the tracking files `compose/compose.fdo-102` and `compose/compose.fdo-98`), a pull request titled `FDO: <COMPOSE_ID>` is created, auto merge is enabled, and a `/test-fdo` comment is added.

Tests are routed by RHEL version:
- **RHEL 10.x** → runs the **Go** FDO client and server tests (`go-fdo-ci` package-mode, `tag:rpm`) against `go-fdo-client` and `go-fdo-server` (manufacturer, rendezvous, owner) from the nightly compose
- **RHEL 9.x** → runs the **Rust** FDO onboarding tests (`fido-device-onboard-rs` tests) against the `fdo-*` client and server packages from the nightly compose (`go-fdo-server` is not shipped on RHEL 9)

Both implementations install the FDO client and servers from the same nightly compose, so each compose run validates both sides of onboarding. The `FDO:` title prefix and `fdo-test` label keep these PRs distinct from Edge compose PRs.

Manual dispatch is available via the Actions tab (`fdo-dispatch.yml`): provide a compose name (e.g. `RHEL-10.2-Nightly` or `RHEL-9.8.0-Nightly`) and optional architecture (default: both x86_64 and aarch64) to run tests on demand without a PR.

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
| `/test-f46-iot` | Fedora IoT 46 tests |
| `/test-fdo` | FDO client and server tests routed by compose (Go on RHEL 10.x, Rust on RHEL 9.x) |

## AWS credentials and test timeouts

The RHEL 9.2, 9.4, 9.6, 9.8, CentOS Stream 9, and AWS AMI cleanup workflows use GitHub OIDC to obtain temporary AWS credentials with `aws-actions/configure-aws-credentials` v6.3.0, pinned to a full commit SHA.

Before running these workflows:

- Set the `CI_ROLE_ARN` repository secret to the IAM role ARN.
- Configure the role to trust GitHub's OIDC provider (`token.actions.githubusercontent.com`) with conditions allowing the intended repository and workflow context.
- Set the role's `MaxSessionDuration` to 43,200 seconds (12 hours). AWS rejects a requested session duration above this limit.

Testing Farm jobs request 12-hour credentials to allow time for queued tests and cleanup. They pass the temporary access key, secret key, and session token to Testing Farm. These credentials expire automatically and are not refreshed by the waiting GitHub action.

| Setting | Minutes | Purpose |
|---------|---------|---------|
| Job `timeout-minutes` | 360 | Overall GitHub job limit, including setup and reporting |
| Testing Farm step `timeout-minutes` | 340 | Limit for submitting the request and waiting for results |
| Testing Farm `pipeline_settings.timeout` | 330 | Remote pipeline timeout enforced by Testing Farm |

The 20-minute difference between the job and step limits is shared by setup and reporting. The job deadline takes precedence if setup consumes that budget. Queueing and result delivery can consume the margin between the pipeline and step limits. Stopping the GitHub step does not guarantee cancellation of the remote pipeline.

Use the native step timeout instead of the `timeout` input of the pinned Testing Farm action (`230555baceb860aa468d216f1822974836b965d1`): its polling loop waits four times the configured number of minutes when a request remains active.

The AWS AMI cleanup workflow requests 7,200-second (2-hour) credentials for its 60-minute cleanup step.

Keep the static AWS secrets while `rhel-9-5.yml`, `fedora-43.yml`, and `fedora-rawhide.yml` still reference them.

The AWS AMI cleanup workflow supports manual dispatch in `virt-s1/rhel-edge`. In the Actions tab, open the cleanup workflow, choose **Run workflow**, and select a branch or tag containing the workflow changes. Dispatches through the CLI or API can specify a branch or tag name. The selected branch or tag must exist in that repository; the cleanup job is skipped in forks.

The Testing Farm workflows use `/test-*` comments and do not support manual dispatch. These comments execute the workflow definition from the default branch, so they cannot validate workflow YAML changes in an unmerged PR. Pre-merge validation requires a separately arranged test workflow that executes the proposed definition. After merge, use the appropriate `/test-*` comment to validate the updated workflow.

Confirm successful OIDC role assumption and AWS operations in the cleanup and Testing Farm runs.

## `rhel-edge` repository CI

Any pull request will trigger **Lint** job automatically. Edge tests will not be run by default. To run Edge test, add comment with content according to the table above.

Lint checks (defined in `.github/workflows/lint.yml`):

| Check | Local equivalent |
|-------|------------------|
| Commit messages | CI only (`commitlint`) |
| Spelling | `codespell --check-filenames --ignore-words-list bu` |
| Shell scripts | `find . -name '*.sh' -print0 \| xargs -0 shellcheck -e SC1091 -e SC2002 -e SC2317 -e SC2329` |
| YAML | `yamllint .` |

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
