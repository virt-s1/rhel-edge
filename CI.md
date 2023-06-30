# RHEL for Edge CI

## RHEL 8.x and 9.x nightly compose CI

RHEL 8 compose trigger and RHEL 9 compose trigger will be run four times every day. They will check **COMPOSE_ID** of their **latest** compose link. If the **COMPOSE_ID** can't be found in ***compose/compose.8x*** or ***compose/compose.9x***, a new pull request will be created, auto merge will be enabled, and a comment */test-rhel-8-x* or */test-rhel-9-x* will be added. That will trigger all RHEL for Edge tests on RHEL 8.x and 9.x VM deployed on PSI OpenStack.

## CentOS Stream 8 and 9 compose CI

CentOS Stream compose trigger will be run twice every day. They will check **COMPOSE_ID** of their **latest** compose link. If the **COMPOSE_ID** can't be found in ***compose/compose.cs8*** or ***compose/compose.cs9***, a new pull request will be created, auto merge will be enabled, and a comment */test-cs8* or */test-cs9* will be added. That will trigger all RHEL for Edge tests on CentOS Stream 8 or 9 VM which will be deployed on Google Cloud.

## Fedora compose CI

Fedora 3x compose will be triggered once a day. It's a cron job. The tests will be deployed and run on Google Cloud

Fedora rawhide compose trigger will be run twice every day. They will check **COMPOSE_ID** of their **latest** compose link. If the **COMPOSE_ID** can't be found in ***compose/compose.rawhide***, a new pull request will be created, auto merge will be enabled, and a comment */test-rawhide* will be added. That will trigger all tests on Fedora rawhide VM which will be deployed on Google Cloud.

## How to run compose test manually

Send a pull request and add comment according to the following table:

| Comment Content | Triggered Tests |
| --------------- | --------------- |
| `/test-rhel-8-x` | `ostree.sh`, `ostree-ng.sh`, `ostree-raw-image.sh`, `ostree-simplified-installer.sh`, `ostree-rebase.sh` |
| `/test-rhel-9-x` | `ostree.sh`, `ostree-ng.sh`, `ostree-raw-image.sh`, `ostree-simplified-installer.sh`, `ostree-8-to-9.sh` |
| `/test-rhel-8-x-virt`, `/test-rhel-9-x-virt`, `/test-cs8-virt`, `/test-cs9-virt`, `test-f3x-virt`, `test-rawhide-virt` | `ostree.sh` |
| `/test-rhel-8-x-ng`, `/test-rhel-9-x-ng`, `/test-cs8-ng`, `/test-cs9-ng`, `test-f3x-ng`, `test-rawhide-ng` | `ostree-ng.sh` |
| `/test-rhel-8-x-raw`, `/test-rhel-9-x-raw`, `/test-cs8-raw`, `/test-cs9-raw`, `test-f3x-raw`, `test-rawhide-raw` | `ostree-raw-image.sh` |
| `/test-rhel-8-x-simplified`, `/test-rhel-9-x-simplified`, `/test-cs8-simplified`, `/test-cs9-simplified` | `ostree-simplified-installer.sh` |
| `/test-rhel-9-x-8to9`, `/test-cs9-8to9` | `ostree-8-to-9.sh` |
| `/test-rhel-9-x-9to9` | `ostree-9-to-9.sh` |
| `/test-rhel-9-x-ignition`, `/test-cs9-ignition` | `ostree-ignition.sh` |
| `/test-f3x-minimal`, `/test-rawhide-minimal` | `minimal-raw.sh` |

## rhel-edge repository CI

Any pull request will trigger **Lint** job automatically. Edge tests will not be run by default. To run Edge test, add comment with content according to above table.

## FDO container CI

FDO container test will be run weekly. The `latest` tag containers will be pulled.

## RHEL for Edge package CI

RHEL for Edge packages, like `ostree`, `rpm-ostree`, `greenboot`, `rust-coreos-installer`, `fido-device-onboard`, will be monitored by brew message on UMB. The message will be cached when package finished its building and the test will be run against new package.

## Customer case

Customer case related test will be run weekly for regression.
