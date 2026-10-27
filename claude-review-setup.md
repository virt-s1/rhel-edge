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

- Triggers on `pull_request` `opened` and `synchronize`.
- Posts a summary comment plus inline review comments using the workflow's
  `GITHUB_TOKEN` (`pull-requests: write`); no GitHub App is required for the
  pilot.
- `concurrency` cancels an in-progress review when new commits land on the same
  PR, to avoid paying for reviews of stale diffs.
- **Only works on same-repo branches, not forks.** GitHub Actions does not
  inject an OIDC token for `pull_request` events triggered from a fork, so
  this check will always fail on external-contributor PRs — that's expected,
  not a bug.

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
