# Claude AI PR review setup

This repo runs an automated AI reviewer on pull requests via the
[Claude Code GitHub Action](https://github.com/anthropics/claude-code-action)
(`.github/workflows/claude-review.yml`). It is the pilot from Project Judoon
(THEEDGE-4881), which chose the Action over building a bespoke GitHub App or
adopting a hosted SaaS reviewer.

## Authentication

The workflow authenticates to Google Vertex AI using Workload Identity
Federation (WIF): keyless OIDC, short-lived per-job tokens, nothing to store
or rotate. No Anthropic API key, no service account, and no repo secrets are
used — only plain repo variables (see below).

This workflow is intentionally generic: it has no Red Hat-specific
infrastructure values baked in. Maintainers with access to Red Hat's internal
`team-operations` repo can find the real GCP project, WIF pool, and IAM setup
steps in `dev/claude-code-review-setup.md` there.

## Required repo variables

Set these under Settings → Secrets and variables → Actions → Variables. The
workflow has no fallback defaults, so it fails fast (not silently against the
wrong project) if any are unset.

| Variable | Purpose |
| --- | --- |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full WIF provider resource path |
| `ANTHROPIC_VERTEX_PROJECT_ID` | GCP project hosting Vertex AI |
| `CLOUD_ML_REGION` | Vertex endpoint region (`global` is usually right — some models aren't available on single-region endpoints) |
| `CLAUDE_REVIEW_MODEL` | Vertex model ID, e.g. `claude-sonnet-5` — must be enabled in the target project's Model Garden |

## How it runs

- Triggers on `pull_request_target` `opened` and `synchronize` (skipping
  PRs that only touch `compose/`, which are CI-managed and have nothing to
  review).
- Posts a summary comment plus inline review comments using the workflow's
  `GITHUB_TOKEN` (`pull-requests: write`); no GitHub App is required for the
  pilot.
- `concurrency` cancels an in-progress review only when new commits land on
  the same PR, to avoid paying for reviews of stale diffs. A PR comment
  (valid `/claude-review` or not) never cancels an in-progress review; it
  queues behind it instead.
- **Works on fork PRs.** `pull_request_target` (not `pull_request`) runs in
  the base repo's context, so secrets/variables are available even when the
  PR is from a fork. As a trust gate, the job only runs if the PR author's
  GitHub association with this repo is `OWNER`, `MEMBER`, or `COLLABORATOR`
  — PRs from first-time or outside contributors are skipped automatically.
  Use the manual trigger below to review one of those anyway.

### Manual trigger

A repo collaborator (`OWNER`/`MEMBER`/`COLLABORATOR`) can force a review on
any PR, open or closed, by commenting:

```
/claude-review
```

This is mainly for PRs the automatic trust gate skips — e.g. a first-time
contributor's otherwise-legitimate PR. The trust check for this path looks
at the *commenter's* association rather than the PR author's, since the
comment thread is open to anyone. The comment must contain the exact
`/claude-review` command at the start of a line (not just anywhere
mid-sentence) — it doesn't need to be the very first thing in the comment.
The workflow reviews whatever the PR's head commit is at the time the
job runs (not necessarily what it was when the comment was posted, if new
commits land in between), and works the same whether the PR is still open
or has since been closed/merged.

Note this is deliberately a manual override: it does not skip `compose/`
tracking-file PRs like the automatic `paths-ignore` check does, so a
`/claude-review` comment on one of those still runs (and bills) a review.

**Not yet confirmed:** claude-code-action's inline PR comments resolve diff
positions from the triggering event's context, which differs between
`pull_request_target` and `issue_comment`. The automatic path is proven (it's
been running), but the first real `/claude-review` run after this lands
should be checked to confirm inline comments still anchor to the right
lines, not just the summary comment.

Like any other GitHub Actions workflow change, edits to this workflow file
only take effect once merged to the default branch — both
`pull_request_target` and `issue_comment` always run the workflow definition
from the base/default branch, not from the PR that's modifying it. A PR that
changes `claude-review.yml` itself can't be used to test its own new
behavior; test from a follow-up PR (or comment) after merging.

## Testing the pilot

1. Confirm the target repo's auth is set up (ask a maintainer if the repo
   variables above aren't set yet).
2. Open a small test PR from a branch in this repo (not a fork) and confirm
   a review is posted.
3. Compare review quality against gemini-code-assist on the same PR.

## Cost and billing

Vertex usage is billed to whatever GCP project `ANTHROPIC_VERTEX_PROJECT_ID`
points at. Rough estimate from the spike: ~$10-$15 per ~50 PRs.

## Contributing note

Per `AGENTS.md`, AI-assisted changes need an `Assisted-by: AGENT_NAME
(MODEL_VERSION)` trailer and a human sign-off before commit.
