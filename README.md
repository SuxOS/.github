# SuxOS/.github — shared CI/autonomy pipeline

Reusable GitHub Actions workflows extracted from `colinxs/sux`, phase 1 of the
SuxOS migration (see `sux-mcp/docs/knowledge/refactor-runbook.md`). Every
SuxOS repo inherits this pipeline via a thin caller stub instead of copying
1,400+ lines of workflow YAML per repo.

## The two groups

**Gates** (required checks that block merge):
`ci.yml` · `security-review.yml` · `audit.yml` · `health.yml`

**Autonomy pipeline** (keeps the merge queue moving hands-off):
`automerge.yml` · `pr-auto-update.yml` · `pr-drain.yml` · `pr-watch.yml` ·
`claude.yml` · `claude-autofix.yml` · `budget-guard.yml` · `skill-sync.yml`

**Backlog pipeline** (turns latent work into merged/staged PRs — propose → investigate → build):
`fixer.yml` (propose issues w/ confidence) · `triage.yml` (independently verify + opt-out-queue
for build) · `issue-build.yml` (cluster n issues → m PRs, one build session per cluster;
`confidence:high` clusters auto-merge, the rest stage). Full design +
state machine + auth split: [docs/design/backlog-pipeline.md](docs/design/backlog-pipeline.md).
Caller-stub examples below.

## Auth: subscription vs metered API

Every Claude workflow authenticates one of two ways:

- **`CLAUDE_CODE_OAUTH_TOKEN`** (Pro/Max subscription, from `claude setup-token`) — used by
  `fixer` / `triage` / `issue-build` / `claude` / `claude-autofix`. `claude-code-action` runs
  Claude Code billed to your subscription, not per-token API. This is the high-volume
  automation.
- **`ANTHROPIC_API_KEY`** (metered) — used ONLY by `security-review.yml`, on purpose: it's a
  required merge gate, and if it ran on the subscription an exhausted pool would jam the merge
  queue for everyone. See the design doc § auth split — do not "unify" it to OAuth.

Set both as **org-level** secrets so every repo inherits them via `secrets: inherit`.

## Caller-stub pattern

Each file here is a `workflow_call` reusable workflow with `inputs:` (defaults
mirror sux-mcp's layout — override the ones that don't fit your repo). Callers
almost always want `secrets: inherit` so the App-token / Anthropic-key secrets
flow through without being re-declared per repo.

```yaml
# .github/workflows/ci.yml in a SuxOS caller repo
name: CI
on:
  push:
  pull_request:
jobs:
  ci:
    uses: SuxOS/.github/.github/workflows/ci.yml@main
    with:
      node-version: "22"
      wrangler-config: "" # this repo doesn't deploy a Worker — skip the dry-run step
    secrets: inherit
```

A caller with a Worker to dry-run-deploy just keeps the defaults:

```yaml
jobs:
  ci:
    uses: SuxOS/.github/.github/workflows/ci.yml@main
    secrets: inherit
```

### Backlog-pipeline caller stubs

The event triggers live in the caller (a `workflow_call` file can't re-expose
`issues:` / `schedule:`). See [docs/design/backlog-pipeline.md](docs/design/backlog-pipeline.md).

```yaml
# fixer.yml — propose. Time/manual (nothing "happens" to trigger a scan).
name: Fixer
on:
  schedule: [{ cron: "17 8 * * *" }] # daily, off-minute; drop for manual-only
  workflow_dispatch:
jobs:
  fixer: { uses: SuxOS/.github/.github/workflows/fixer.yml@main, secrets: inherit }
```

```yaml
# triage.yml — investigate. Fires on a newly-filed issue (fixer's or a human's) + manual drain.
name: Triage
on:
  issues: { types: [opened, reopened] }
  workflow_dispatch:
jobs:
  triage: { uses: SuxOS/.github/.github/workflows/triage.yml@main, secrets: inherit }
```

```yaml
# issue-build.yml — collate + build. Fires when queued-for-build is applied + manual drain.
name: Issue build
on:
  issues: { types: [labeled] }
  workflow_dispatch:
jobs:
  issue-build:
    if: github.event_name != 'issues' || github.event.label.name == 'queued-for-build'
    uses: SuxOS/.github/.github/workflows/issue-build.yml@main
    with: { gates-summary: "npm run type-check · npm test · npm run lint" }
    secrets: inherit
```

Labels each repo needs once (`gh label create`): `queued-for-build`, `building`,
`triaged`, `confidence:high|medium|low`, plus the usual `automerge` /
`needs-review` / `needs-human` / `hold`.

### Required secrets/vars in the caller repo

- `CLAUDE_CODE_OAUTH_TOKEN` — Pro/Max subscription token (`claude setup-token`);
  arms `fixer`/`triage`/`issue-build`/`claude`/`claude-autofix`. Org-level secret.
- `ANTHROPIC_API_KEY` — metered; arms `security-review.yml` ONLY (see § auth split).
  Every Claude job preflights on its token being set and is otherwise inert.
- `SUX_BOT_APP_ID` / `SUX_BOT_PRIVATE_KEY` — a GitHub App installed on the
  caller repo, used by every workflow that pushes or arms auto-merge.
- Repo variable `ACTIONS_BUDGET_PAUSED` — set/read by `budget-guard.yml`; you
  don't need to create it yourself, the guard creates it on first trip.
- Branch protection on `main` (strict, requiring at minimum `Type-check &
  build`, `security-review`, `npm audit & SBOM`) — `automerge.yml`
  refuses to arm auto-merge unless it can verify these are actually required,
  so set this up before wiring the caller stub for `automerge.yml`.

### `workflow_run` — the one trigger that can't cross the `workflow_call` boundary

`claude-autofix.yml` needs a `workflow_run: workflows: ["CI"]` trigger, and
GitHub does not let a reusable `workflow_call` workflow declare that trigger
for you — the caller repo's own `.github/workflows/claude-autofix.yml` stub
must declare `on: workflow_run: workflows: ["CI"]` itself and then `uses:` this
reusable file for the job body. Same idea applies to any other event trigger
(`schedule`, `pull_request_target`, etc.) — those live in the caller's stub,
`workflow_call` only supplies the reusable job.

## Two hard-won gotchas preserved from sux-mcp (read before editing these files)

1. **Push with a GitHub App token, never `GITHUB_TOKEN`.** GitHub suppresses
   new workflow runs for events attributed to `GITHUB_TOKEN` (anti-recursion),
   so a bot push/rebase/merge done with the default token silently never
   re-fires downstream CI — the PR looks stuck green with a required check
   permanently missing. Every workflow here that pushes or merges (autofix,
   mention, auto-update, drain, automerge, budget-guard) mints a
   `SUX_BOT`-style App token via `actions/create-github-app-token` first.

2. **Read verdicts from `structured_output`, never a written file.**
   `claude-code-action` runs the model in a sandbox `cwd` that is not
   `$GITHUB_WORKSPACE`, so a model-written verdict file can land somewhere the
   gate step never reads — this shipped weeks of silently-advisory-passing
   security reviews in sux-mcp. Always pass `--json-schema` in `claude_args`
   and read the verdict via
   `fromJSON(steps.<id>.outputs.structured_output).<field>` — it's
   cwd-independent.

Full details: `sux-mcp/docs/knowledge/auth-github-ci.md`.
