# SuxOS/.github — shared CI/autonomy pipeline

Reusable GitHub Actions workflows extracted from `colinxs/sux`, phase 1 of the
SuxOS migration (see `sux-mcp/docs/knowledge/refactor-runbook.md`). Every
SuxOS repo inherits this pipeline via a thin caller stub instead of copying
1,400+ lines of workflow YAML per repo.

## The two groups

**Gates** (required checks that block merge):
`ci.yml` · `security-review.yml` · `audit.yml` · `health.yml` — secret scanning is
GitHub's native secret-scanning + push-protection (repo Settings → Security), not
a workflow here; the standalone `secret-scan.yml`/`gitleaks` gate was retired.

**Autonomy pipeline** (keeps the merge queue moving hands-off):
`automerge.yml` · `pr-auto-update.yml` · `pr-drain.yml` · `pr-watch.yml` ·
`waitch.yml` · `claude.yml` · `claude-autofix.yml` · `skill-sync.yml` — the org-wide
`budget-guard.yml` gate was retired; there's no `ACTIONS_BUDGET_PAUSED` var to set.

**Backlog pipeline** (turns latent work into merged/staged PRs — propose → investigate → build):
`fixer.yml` (propose issues w/ confidence) · `triage.yml` (independently verify + opt-out-queue
for build) · `issue-build.yml` (cluster n issues → m PRs, one build session per cluster;
`confidence:high` clusters auto-merge, the rest stage). Full design +
state machine + auth split: [docs/design/backlog-pipeline.md](docs/design/backlog-pipeline.md).
Caller-stub examples below.

## Auth: unified on the subscription token

Every Claude workflow, including `security-review.yml`, authenticates with
**`CLAUDE_CODE_OAUTH_TOKEN`** (Pro/Max subscription, from `claude setup-token`).
`claude-code-action` runs Claude Code billed to your subscription, not per-token API.

`security-review.yml` was previously kept on a metered `ANTHROPIC_API_KEY` on purpose: it's
a required merge gate, and an exhausted subscription pool would jam the merge queue for
everyone. That split was dropped by explicit decision to consolidate on one token —
**accepted risk:** if the OAuth pool exhausts, the gate can't run and nothing merges. See
the design doc § auth split for the revert path if that becomes a problem in practice.

Set `CLAUDE_CODE_OAUTH_TOKEN` as an **org-level** secret so every repo inherits it via
`secrets: inherit`.

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
  arms every Claude workflow, including `security-review.yml` (see § auth split for
  the accepted-risk tradeoff on the required gate). Org-level secret.
  Every Claude job preflights on its token being set and is otherwise inert.
- `SUX_BOT_APP_ID` / `SUX_BOT_PRIVATE_KEY` — a GitHub App installed on the
  caller repo, used by every workflow that pushes or arms auto-merge.
- Branch protection or a ruleset on the default branch (strict, requiring at
  minimum `Type-check & build`, `security-review`, `npm audit & SBOM`) —
  `automerge.yml` refuses to arm auto-merge unless it can verify these are
  actually required, so set this up before wiring the caller stub for
  `automerge.yml`. Note it can only read rulesets with the App token (the
  classic branch-protection API 403s for an App installation token), so a
  ruleset — not classic branch protection — is what it actually verifies.

### Required labels

Every `gh pr edit --add-label` / `has_label` check in these workflows is wrapped in
`2>/dev/null || true`, so a caller repo that skips creating a label doesn't error —
the label-gated behavior just silently no-ops instead. Create these once per caller
repo (`bug` is a GitHub default label, so it needs no setup):

- `automerge` — auto-merge-eligible (alongside `bug`/`security`/`chore-safe`, or a
  safe-type commit title); `automerge.yml` also self-applies it once auto-merge is armed.
- `hold` — blocks all automation on a PR: `automerge.yml` refuses to arm,
  `pr-auto-update.yml` won't update-branch it, `pr-drain.yml`/`pr-watch.yml` skip it.
  Auto-applied by `security-review.yml` on a critical/high finding, or fail-closed
  when the verdict is missing/unreadable.
- `needs-human` — not safe for unattended handling. `claude-autofix.yml` applies it
  once its retry cap is hit; `triage.yml` applies it to issues it doesn't judge buildable.
- `feature` — net-new feature work; `automerge.yml` and `pr-drain.yml`'s reconcile pass
  both refuse to auto-merge a `feature`-labeled PR — a human always merges it.
- `chore-safe` — safe refactor/cleanup/docs; one of the auto-merge-eligible labels.
- `keep` — opts a PR out of `pr-drain.yml`'s close-stale sweep (alongside `hold`)
  without blocking any other automation.
- `security` — security fix; auto-merge-eligible like `chore-safe`/`bug`/`automerge`.
- `self-improve` — lets a Bot-authored PR pass `automerge.yml`'s trusted-author check
  (addable only by write access) and keeps bot PRs out of `pr-drain.yml`'s close-stale sweep.

```bash
gh label create automerge    -c 2da44e -d "Bot may auto-merge when green (bug/security/chore-safe/automerge only)" --force
gh label create hold         -c e11d21 -d "Block all automation on this PR/issue" --force
gh label create needs-human  -c d93f0b -d "Not safe for unattended handling — needs a human" --force
gh label create feature      -c 1d76db -d "Net-new feature — needs a human, never auto-merged" --force
gh label create chore-safe   -c 0e8a16 -d "Safe refactor/cleanup/docs — eligible for auto-merge when green" --force
gh label create keep         -c c5def5 -d "Opt out of pr-drain's close-stale sweep" --force
gh label create security     -c b60205 -d "Security fix — eligible for auto-merge when green" --force
gh label create self-improve -c ededed -d "Bot-authored PR trusted for auto-merge (public-repo guard)" --force
```

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
   mention, auto-update, drain, automerge, skill-sync) mints a
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
