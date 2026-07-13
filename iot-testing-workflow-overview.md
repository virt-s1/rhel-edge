# Fedora IoT Testing Workflow Overview

**Purpose**: Understand how tests are triggered and executed.

## Key difference from RHEL for Edge

Fedora IoT tests **do not build images** — they download pre-built compose artifacts
(ISO, raw image, OCI archive) from `kojipkgs.fedoraproject.org` and validate them.

## Active streams

| Stream | Status | Testing Farm compose | OSTree ref |
|--------|--------|----------------------|------------|
| Fedora IoT 44 (F44) | Stable | `Fedora-44` | `fedora/stable/${ARCH}/iot` |
| Fedora IoT 45 (F45) | Active | `Fedora-44` | `fedora/rawhide/${ARCH}/iot` |

## Data flow

```
Daily 13:00 UTC
      │
      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 1. DETECT NEW COMPOSE                                               │
│    File: .github/workflows/trigger-iot.yml                          │
│    - Fetch latest compose from kojipkgs.fedoraproject.org           │
│    - Check F44: compare with compose/compose.f44-iot                │
│    - Check F45: compare with compose/compose.f45-iot                │
│    - If new compose found, create PR and add trigger comment        │
│      F44 → /test-f44-iot   F45 → /test-f45-iot                      │
└─────────────────────────────────────────────────────────────────────┘
                     │
                     │ PR created with compose ID as title
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. TRIGGER TESTS                                                    │
│    F44: .github/workflows/fedora-iot-44.yml  (/test-f44-iot)        │
│    F45: .github/workflows/fedora-iot-45.yml  (/test-f45-iot)        │
│    - Call Testing Farm                                              │
└─────────────────────────────────────────────────────────────────────┘
                     │
                     │ Testing Farm provisions VM
                     │ TMT filters by context and plan regex
                     ▼
         ╔═══════════════════════════════════════╗
         ║    ON TESTING FARM VM (steps 3-5)     ║
         ╚═══════════════════════════════════════╝
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. SELECT TESTS (TMT)                                               │
│    File: tmt/plans/iot-test.fmf                                     │
│    - Filter plans by regex: "iot-x86"                               │
│    - Match: /iot-x86-installer, /iot-x86-simplified-installer, ...  │
│    - For each plan: Set TEST_CASE env var                           │
│    - Read test metadata: tmt/tests/iot-test.fmf                     │
└─────────────────────────────────────────────────────────────────────┘
                     │
                     │ Example: TEST_CASE=iot-installer
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. DISPATCH TEST                                                    │
│    File: tmt/tests/test.sh                                          │
│    - Read $TEST_CASE                                                │
│    - Route: iot-installer → ./iot-installer.sh                      │
└─────────────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. EXECUTE TEST                                                     │
│    File: iot-installer.sh (or other iot-*.sh)                       │
│    - Download artifact → Install into VM → Validate                 │
│    - Exit: 0 (pass) or 1 (fail)                                     │
└─────────────────────────────────────────────────────────────────────┘
                     │
                     │ Test results returned to GitHub Actions
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. REPORT RESULTS                                                   │
│    F44: fedora-iot-44.yml → PR check: iot-f44-x86 ✅/❌             │
│    F45: fedora-iot-45.yml → PR check: iot-f45-x86 ✅/❌             │
│    - Sends test results to Slack                                    │
└─────────────────────────────────────────────────────────────────────┘
```

## File interconnections

### 1. Compose detection → PR creation

```
trigger-iot.yml
    │
    ├─ Reads: compose/compose.f44-iot           [list of tested F44 composes]
    ├─ Reads: compose/compose.f45-iot           [list of tested F45 composes]
    ├─ Fetches: kojipkgs.fedoraproject.org      [compose server]
    │
    └─ Creates PR per stream
         F44 - Title: Fedora-IoT-44-YYYYMMDD.N  Comment: /test-f44-iot
         F45 - Title: Fedora-IoT-45-YYYYMMDD.N  Comment: /test-f45-iot
```

### 2. PR comment → Testing Farm

```
fedora-iot-44.yml (triggered by /test-f44-iot)        fedora-iot-45.yml (triggered by /test-f45-iot)
    │                                                       │
    ├─ Job: check-permissions                               ├─ Job: check-permissions
    │    ├─ Checks: User permissions via GitHub API         │    ├─ Checks: User permissions via GitHub API
    │    └─ Extracts from PR                                │    └─ Extracts from PR
    │         - sha (commit to test)                        │         - sha (commit to test)
    │         - ref (branch name)                           │         - ref (branch name)
    │         - compose_id (from PR title)                  │         - compose_id (from PR title)
    │                                                       │
    └─ Job: iot-44-x86                                      └─ Job: iot-45-x86
         └─ Testing Farm                                         └─ Testing Farm
              - compose: Fedora-44                                    - compose: Fedora-44
              - tmt_context: "arch=x86_64;distro=fedora-44"            - tmt_context: "arch=x86_64;distro=fedora-44"
              - tmt_plan_regex: iot-x86                               - tmt_plan_regex: iot-x86
```

### 3. Testing Farm → TMT → test selection

```
Testing Farm provisions VM
    ↓
TMT reads: tmt/plans/iot-test.fmf
    │
    ├─ Filters plans by regex: "iot-x86"
    │    - Matches
    │        - /iot-x86-installer
    │        - /iot-x86-simplified-installer
    │        - /iot-x86-raw-image
    │        - /iot-x86-bootc
    │
    └─ For each plan, TMT:
         1. Reads tmt/tests/iot-test.fmf (metadata)
         2. Sets environment: TEST_CASE=iot-installer
         3. Executes: tmt/tests/test.sh
```

**Example code**:
```yaml
/iot-x86-installer:
    summary: Test fedora-iot x86_64 installer ISO image
    environment+:
        TEST_CASE: iot-installer    # ← This var goes to test.sh
```

### 4. Test dispatcher → specific test script

```
test.sh
    │
    ├─ Reads: $TEST_CASE environment variable
    │
    └─ if/elif/else conditional routes to script
         - iot-installer              → ./iot-installer.sh
         - iot-simplified-installer   → ./iot-simplified-installer.sh
         - iot-raw-image              → ./iot-raw-image.sh
         - iot-bootc                  → ./iot-bootc-image.sh
```

**Example Code**:
```bash
elif [ "$TEST_CASE" = "iot-installer" ]; then
    ./iot-installer.sh    # ← Executes iot-installer.sh
```

### 5. Test execution

Each IoT test script derives the IoT version from `${COMPOSE}` (e.g. `Fedora-IoT-45-20260710.0` → `45`) and uses `IOT_VERSION` to select the correct OSTree ref, OS variant, and artifact name:

| `IOT_VERSION` | `OSTREE_REF` | `OS_VARIANT` |
|---------------|------------|-----------|
| `44` | `fedora/stable/${ARCH}/iot` | `fedora-unknown` |
| `45` | `fedora/rawhide/${ARCH}/iot` | `fedora-rawhide` |

### 6. Results reporting

```
fedora-iot-{44,45}.yml (after Testing Farm completes)
    │
    ├─ Updates PR status: ✅/❌ iot-f{44,45}-x86
    │
    └─ Sends Slack notification to alerts-fedora-iot-compose-inspector (private):
         - Format: emoji distribution | architecture | compose ID | test log link
```

## Key files and their role

| File | Purpose | What it does |
|------|---------|--------------|
| `.github/workflows/trigger-iot.yml` | Detect compose | Checks for new F44/F45 composes, creates PRs, adds trigger comments |
| `.github/workflows/fedora-iot-44.yml` | Trigger F44 tests | Triggered by `/test-f44-iot`, calls Testing Farm with `Fedora-44` |
| `.github/workflows/fedora-iot-45.yml` | Trigger F45 tests | Triggered by `/test-f45-iot`, calls Testing Farm with `Fedora-44` |
| `compose/compose.f44-iot` | F44 compose history | Tracks already-tested F44 compose IDs |
| `compose/compose.f45-iot` | F45 compose history | Tracks already-tested F45 compose IDs |
| `files/fedora-44.json` | `osbuild-composer` repos | Fedora 44 stable repository definitions |
| `files/fedora-45.json` | `osbuild-composer` repos | Fedora 45 Rawhide repository definitions |
| `tmt/plans/iot-test.fmf` | Test selection | Defines which tests run |
| `tmt/tests/iot-test.fmf` | Test metadata | Points to `test.sh`, sets duration |
| `tmt/tests/test.sh` | Test dispatcher | Selects which test script to run |
