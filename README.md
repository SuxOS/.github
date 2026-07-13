# SuxOS/.github — shared CI/autonomy pipeline

Reusable GitHub Actions workflows extracted from `colinxs/sux`, phase 1 of the
SuxOS migration (see `sux-mcp/docs/knowledge/refactor-runbook.md`). Every
SuxOS repo inherits this pipeline via a thin caller stub instead of copying
1,400+ lines of workflow YAML per repo.

## The two groups

**Gates** (required checks that block merge):
`ci.yml` · `security-review.yml` · `audit.yml` · `secret-scan.yml` · `health.yml`

**Autonomy pipeline** (keeps the merge queue moving hands-off):
`automerge.yml` · `pr-auto-update.yml` · `pr-drain.yml` · `pr-watch.yml` ·
`claude.yml` · `claude-autofix.yml` · `budget-guard.yml` · `skill-sync.yml`

**Backlog pipeline** (finds work, builds it, feeds it into the autonomy pipeline
above — nothing here merges anything itself):
`fixer.yml` (scan a repo → file issues) · `issue-build.yml` (cluster related
`queued-for-build` issues → one PR per cluster, n issues to m PRs, never n to
1). `queued-for-build` is a manual human label — `fixer.yml` never applies it —
so nothing gets autonomously built until a human opts an issue in. PRs
`issue-build.yml` opens use the exact same safe-type/label eligibility rule as
`automerge.yml`, so they either auto-merge when genuinely safe or stop at a
human like any other PR — this pipeline has no special-case merge path.

```yaml
# .github/workflows/fixer.yml in a SuxOS caller repo — manual for now
name: Fixer
on:
  workflow_dispatch:
jobs:
  fixer:
    uses: SuxOS/.github/.github/workflows/fixer.yml@main
    secrets: inherit
```

```yaml
# .github/workflows/issue-build.yml in a SuxOS caller repo — event-triggered
# (fires when a human labels an issue queued-for-build; workflow_call can't
# re-expose the issues: event, so the caller owns this trigger) PLUS a daily
# drain + workflow_dispatch, since the cluster job lists every open
# queued-for-build issue by label regardless of trigger — the drain catches
# anything the label event missed (e.g. it fired while budget-guard had this
# workflow paused) and picks up issues a human labeled queued-for-build
# themselves, not just ones fixer.yml filed.
name: Issue build
on:
  issues:
    types: [labeled]
  schedule:
    - cron: "44 7 * * *" # daily drain, offset minute to dodge the top-of-hour rush
  workflow_dispatch:
jobs:
  issue-build:
    if: github.event_name != 'issues' || github.event.label.name == 'queued-for-build'
    uses: SuxOS/.github/.github/workflows/issue-build.yml@main
    with:
      gates-summary: "npm run type-check · npm test · npm run lint"
    secrets: inherit
```

Both repos need a `queued-for-build` label (and the usual `automerge` /
`needs-review` labels `issue-build.yml`'s PRs get tagged with) created once:
`gh label create queued-for-build --description "Human-approved for autonomous clustering + build" --color 5319e7`.

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

### Required secrets/vars in the caller repo

- `ANTHROPIC_API_KEY` — arms every Claude-Code-action job (mention, review,
  autofix, security-review). Every workflow preflights on it being set and is
  otherwise inert — safe to omit until you want those features live.
- `SUX_BOT_APP_ID` / `SUX_BOT_PRIVATE_KEY` — a GitHub App installed on the
  caller repo, used by every workflow that pushes or arms auto-merge.
- Repo variable `ACTIONS_BUDGET_PAUSED` — set/read by `budget-guard.yml`; you
  don't need to create it yourself, the guard creates it on first trip.
- Branch protection on `main` (strict, requiring at minimum `Type-check &
  build`, `security-review`, `gitleaks`, `npm audit & SBOM`) — `automerge.yml`
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
