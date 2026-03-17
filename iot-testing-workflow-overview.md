# Fedora IoT Testing Workflow Overview

**Purpose**: Understand how tests are triggered and executed.

## Key difference from RHEL for Edge

Fedora IoT tests **do not build images** — they download pre-built compose artifacts
(ISO, raw image, OCI archive) from `kojipkgs.fedoraproject.org` and validate them.

## Data flow

```
Daily 13:00 UTC
      │
      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 1. DETECT NEW COMPOSE                                               │
│    File: .github/workflows/trigger-iot.yml                          │
│    - Fetch latest compose from kojipkgs.fedoraproject.org           │
│    - Check if new (compare with compose/compose.f43-iot)            │
│    - If yes, create PR with compose ID as title                     │
│    - Add comment: /test-f43-iot                                     │
└─────────────────────────────────────────────────────────────────────┘
                     │
                     │ PR created with
                     │   title: "Fedora-IoT-43-20260307.0",
                     │   comment: "/test-f43-iot"
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. TRIGGER TESTS                                                    │
│    File: .github/workflows/fedora-iot-43.yml                        │
│    Trigger: /test-f43-iot comment on PR                             │
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
│    File: iot-installer.sh                                           │
│    - Download ISO → Install into VM → Validate                      │
│    - Exit: 0 (pass) or 1 (fail)                                     │
└─────────────────────────────────────────────────────────────────────┘
                     │
                     │ Test results returned to GitHub Actions
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. REPORT RESULTS                                                   │
│    File: .github/workflows/fedora-iot-43.yml                        │
│    - Updates PR status: ✅/❌ iot-f43-x86                           │
│    - Sends test results to Slack                                    │
└─────────────────────────────────────────────────────────────────────┘
```

## File interconnections

### 1. Compose detection → PR creation

```
trigger-iot.yml
    │
    ├─ Reads: compose/compose.f43-iot           [list of tested composes]
    ├─ Fetches: kojipkgs.fedoraproject.org      [compose server]
    │
    └─ Creates PR
         - Title: Fedora-IoT-43-20260307.0
         - Comment: /test-f43-iot               [triggers next step]
```

### 2. PR comment → Testing Farm

```
fedora-iot-43.yml (triggered by /test-f43-iot)
    │
    ├─ Job: check-permissions
    │    ├─ Checks: User permissions via GitHub API
    │    └─ Extracts from PR
    │         - sha (commit to test)
    │         - ref (branch name)
    │         - compose_id (from PR body)
    │
    └─ Job: iot-43-x86
         │
         └─ Calls: Testing Farm
              - Parameters
                  - compose: Fedora-43
                  - arch: x86_64
                  - tmt_plan_regex: "iot-x86"                   [filters test plans]
                  - tmt_context: "arch=x86_64;distro=fedora-43" [used in adjust rules]
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

Example (`iot-installer.sh`): download ISO → install (kickstart) → validate (Ansible playbook `check-ostree-iot.yaml`)

### 6. Results reporting

```
fedora-iot-43.yml (after Testing Farm completes)
    │
    ├─ Updates PR status: ✅/❌ iot-f43-x86
    │
    └─ Sends Slack notification to alerts-fedora-iot-compose-inspector (private):
         - Format: emoji distribution | architecture | compose ID | test log link
```

## Key files and their role

| File | Purpose | What it does |
|------|---------|--------------|
| `.github/workflows/trigger-iot.yml` | Detect compose | Checks for new compose, creates PR, adds `/test-f43-iot` comment |
| `.github/workflows/fedora-iot-43.yml` | Trigger tests | Triggered by `/test-f43-iot` comment, calls Testing Farm |
| `tmt/plans/iot-test.fmf` | Test selection | Defines which tests run |
| `tmt/tests/iot-test.fmf` | Test metadata | Points to `test.sh`, sets duration |
| `tmt/tests/test.sh` | Test dispatcher | Selects which test script to run |
