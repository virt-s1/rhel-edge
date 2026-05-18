# Contributing to `virt-s1/rhel-edge`

This is an integration test repository - no build step is needed. Typical contributions
include new test scripts, CI workflow updates, and adding support for new distro versions
or compose streams.

## Getting started

1. Create a fork.
2. Clone the fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/rhel-edge.git
   cd rhel-edge
   ```
3. Add the upstream remote:
   ```bash
   git remote add upstream https://github.com/virt-s1/rhel-edge.git
   ```

## Git commits

This project follows the [Conventional Commits](https://www.conventionalcommits.org/)
specification, enforced by [`commitlint`](https://commitlint.js.org/) in CI.

### Signing commits

All commits should be signed off to certify that you agree to the
[Developer Certificate of Origin (DCO)](https://developercertificate.org/).

Use the `-s` flag:

```bash
git commit -s -m "fix: correct fallback log message"
```

It is also possible to amend the last commit:

```bash
git commit --amend -s
```

## Pull requests

1. Create a branch from `main`.
2. Make changes and ensure linting passes (see [`CI.md`](CI.md#rhel-edge-repository-ci)).
3. Open a PR against the upstream repository - lint checks run automatically.
4. To run tests, add a `/test-*` comment (see [`CI.md`](CI.md#how-to-run-compose-test-manually)).

## Coding conventions

- Shell scripts start with `set -euox pipefail`.
- All shell scripts must pass `shellcheck` with exclusions: `SC1091`, `SC2002`, `SC2317`, `SC2329`.
- Test scripts follow a consistent internal pattern:
  setup → configure variables per distro → obtain image (Edge: build with `composer-cli`,
  IoT: download pre-built compose image) → deploy (`virt-install` / AWS / vSphere) →
  SSH into guest and run validation checks → cleanup.
- YAML files follow `.yamllint.yml` rules.
