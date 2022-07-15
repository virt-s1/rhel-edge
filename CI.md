# RHEL for Edge CI

## RHEL 8.x and 9.x nightly compose CI

RHEL 8 compose trigger and RHEL 9 compose trigger will be run four times every day. They will check **COMPOSE_ID** of their **latest** compose link. If the **COMPOSE_ID** can't be found in ***compose/compose.86*** or ***compose/compose.87*** or ***compose/compose.90*** or ***compose/compose.91***, a new pull request will be created, auto merge will be enabled, and a comment */test-rhel-8-6* or */test-rhel-8-7* or */test-rhel-9-0* or */test-rhel-9-1* will be added. That will trigger all RHEL for Edge tests on RHEL 8.x and 9.x VM deployed on PSI OpenStack.

## CentOS Stream 8 and 9 compose CI

CentOS Stream compose trigger will be run twice every day. They will check **COMPOSE_ID** of their **latest** compose link. If the **COMPOSE_ID** can't be found in ***compose/compose.cs8*** or ***compose/compose.cs9***, a new pull request will be created, auto merge will be enabled, and a comment */test-cs8* or */test-cs9* will be added. That will trigger all RHEL for Edge tests on CentOS Stream 8 or 9 VM which will be deployed on Google Cloud.

## Fedora rawhide compose CI

Fedora rawhide compose trigger will be run twice every day. They will check **COMPOSE_ID** of their **latest** compose link. If the **COMPOSE_ID** can't be found in ***compose/compose.rawhide***, a new pull request will be created, auto merge will be enabled, and a comment */test-rawhide* will be added. That will trigger all RHEL for Edge tests on Fedora rawhide VM which will be deployed on Google Cloud.

## How to run compose test manually

Send a pull request and add comment according to the following table:

| Comment Content | Triggered Tests |
| --------------- | --------------- |
| `/test-rhel-8-6`, `/test-rhel-8-7`, `/test-cs8`  | `ostree.sh`, `ostree-ng.sh`, `ostree-raw-image.sh`, `ostree-simplified-installer.sh`, `ostree-rebase.sh` |
| `/test-rhel-9-0`, `/test-rhel-9-1`, `/test-cs9`  | `ostree.sh`, `ostree-ng.sh`, `ostree-raw-image.sh`, `ostree-simplified-installer.sh`, `ostree-8-to-9.sh` |
| `/test-rhel-8-6-virt`, `/test-rhel-8-7-virt`, `/test-rhel-9-0-virt`, `/test-rhel-9-1-virt`, `/test-cs8-virt`, `/test-cs9-virt`, `test-rawhide-virt` | `ostree.sh` |
| `/test-rhel-8-6-ng`, `/test-rhel-8-7-ng`, `/test-rhel-9-0-ng`, `/test-rhel-9-1-ng`, `/test-cs8-ng`, `/test-cs9-ng`, `test-rawhide-ng` | `ostree-ng.sh` |
| `/test-rhel-8-6-raw`, `/test-rhel-8-7-raw`, `/test-rhel-9-0-raw`, `/test-rhel-9-1-raw`, `/test-cs8-raw`, `/test-cs9-raw` | `ostree-raw-image.sh` |
| `/test-rhel-8-6-simplified`, `/test-rhel-8-7-simplified`, `/test-rhel-9-0-simplified`, `/test-rhel-9-1-simplified`, `/test-cs8-simplified`, `/test-cs9-simplified` | `ostree-simplified-installer.sh` |
| `/test-rhel-8-6-rebase`, `/test-rhel-8-7-rebase`, `/test-cs8-rebase` | `ostree-rebase.sh` |
| `/test-rhel-9-0-8to9`, `/test-rhel-9-1-8to9`, `/test-cs9-8to9` | `ostree-8-to-9.sh` |

## rhel-edge repository CI

Any pull request will trigger **Lint** job automatically. Edge tests will not be run by default. To run Edge test, add comment with content according to above table.
