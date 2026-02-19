# RHEL for Edge Testing Workflow Overview

**Purpose**: Understand how tests are triggered and executed.

## Data flow

```
Daily 6:00 UTC
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│ 1. DETECT NEW COMPOSE                                   │
│    File: .github/workflows/trigger-cs.yml               │
│    - Fetch latest compose from odcs.stream.centos.org   │
│    - Check if new (compare with compose/compose.cs9)    │
│    - If yes, create PR with compose ID as title         │
│    - Add comment: /test-cs9                             │
└─────────────────────────────────────────────────────────┘
                     │
                     │ PR created with
                     │   title: "CentOS-Stream-9-20260113.0",
                     │   comment: "/test-cs9"
                     ▼
┌─────────────────────────────────────────────────────────┐
│ 2. TRIGGER TESTS                                        │
│    File: .github/workflows/centos-stream-9.yml          │
│    Trigger: /test-cs9 comment on PR                     │
│    - Call Testing Farm (waits ~3h for test completion)  │
└─────────────────────────────────────────────────────────┘
                     │
                     │ Testing Farm provisions VM
                     │ TMT filters by context and plan regex
                     ▼
         ╔═══════════════════════════════════════╗
         ║    ON TESTING FARM VM (steps 3-5)     ║
         ╚═══════════════════════════════════════╝
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│ 3. SELECT TESTS (TMT)                                   │
│    File: tmt/plans/edge-test.fmf                        │
│    - Filter plans by regex: "edge-x86"                  │
│    - Match: /edge-x86-commit, /edge-x86-installer, ...  │
│    - For each plan: Set TEST_CASE env var               │
│    - Read test metadata: tmt/tests/edge-test.fmf        │
└─────────────────────────────────────────────────────────┘
                     │
                     │ Example: TEST_CASE=edge-commit
                     ▼
┌─────────────────────────────────────────────────────────┐
│ 4. DISPATCH TEST                                        │
│    File: tmt/tests/test.sh                              │
│    - Read $TEST_CASE                                    │
│    - Route: edge-commit → ./ostree.sh                   │
└─────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│ 5. EXECUTE TEST                                         │
│    File: ostree.sh                                      │
│    - Build ostree commit → Install into VM              │
│      → Upgrade → Validate                               │
│    - Exit: 0 (pass) or 1 (fail)                         │
└─────────────────────────────────────────────────────────┘
                     │
                     │ Test results returned to GitHub Actions
                     ▼
┌─────────────────────────────────────────────────────────┐
│ 6. REPORT RESULTS                                       │
│    File: .github/workflows/centos-stream-9.yml          │
│    - Updates PR status: ✅/❌ edge-cs-9-x86             │
│    - Sends test results to Slack                        │
└─────────────────────────────────────────────────────────┘
```

## File interconnections

### 1. Compose detection → PR creation

```
trigger-cs.yml
    │
    ├─ Reads: compose/compose.cs9           [list of tested composes]
    ├─ Fetches: odcs.stream.centos.org      [compose server]
    │
    └─ Creates PR
         - Title: CentOS-Stream-9-20260113.0
         - Comment: /test-cs9               [triggers next step]
```

### 2. PR comment → Testing Farm

```
centos-stream-9.yml (triggered by /test-cs9)
    │
    ├─ Job: pr-info
    │    ├─ Checks: User permissions via GitHub API
    │    └─ Extracts from PR
    │         - sha (commit to test)
    │         - ref (branch name)
    │         - compose_id (from PR title)
    │
    └─ Job: edge-cs-9-x86
         │
         └─ Calls: Testing Farm
              - Parameters
                  - compose: CentOS-Stream-9
                  - arch: x86_64
                  - tmt_plan_regex: "edge-x86"                    [filters test plans]
                  - tmt_context: "arch=x86_64;distro=cs-9"        [used in adjust rules]
```

### 3. Testing Farm → TMT → test selection

```
Testing Farm provisions VM
    ↓
TMT reads: tmt/plans/edge-test.fmf
    │
    ├─ Filters plans by regex: "edge-x86"
    │    - Matches
    │        - /edge-x86-commit
    │        - /edge-x86-installer
    │        - /edge-x86-raw-image
    │        - ...
    │
    └─ For each plan, TMT:
         1. Reads tmt/tests/edge-test.fmf (metadata)
         2. Sets environment: TEST_CASE=edge-commit
         3. Executes: tmt/tests/test.sh
```

**Example code**:
```yaml
/edge-x86-commit:
    summary: Test edge commit
    environment+:
        TEST_CASE: edge-commit    # ← This var goes to test.sh
```

### 4. Test dispatcher → specific test script

```
test.sh
    │
    ├─ Reads: $TEST_CASE environment variable
    │
    └─ if/elif/else conditional routes to script
         - edge-commit     → ./ostree.sh
         - edge-installer  → ./ostree-ng.sh
         - edge-raw-image  → ./ostree-raw-image.sh
         - ...
```

**Example Code**:
```bash
if [ "$TEST_CASE" = "edge-commit" ]; then
    ./ostree.sh    # ← Executes ostree.sh
```

### 5. Test execution

Example (`ostree.sh`): compose edge-commit (tar) → install (HTTP boot) → upgrade → validate (Ansible playbook `check-ostree.yaml`)

### 6. Results reporting

```
centos-stream-9.yml (after Testing Farm completes)
    │
    ├─ Updates PR status: ✅/❌ edge-cs-9-x86
    │
    └─ Sends Slack notification to #rhel-edge-ci:
         - Format: emoji distribution | architecture | compose ID | test log link
```

## Key files and their Role

| File | Purpose | What it does |
|------|---------|--------------|
| `.github/workflows/trigger-cs.yml` | Detect compose | Checks for new compose, creates PR, adds `/test-cs9 comment` |
| `.github/workflows/centos-stream-9.yml` | Trigger tests | Triggered by `/test-cs9` comment, calls Testing Farm |
| `tmt/plans/edge-test.fmf` | Test selection | Defines which tests run on which distributions |
| `tmt/tests/edge-test.fmf` | Test metadata | Points to `test.sh`, sets duration |
| `tmt/tests/test.sh` | Test dispatcher | Selects which test script to run |
