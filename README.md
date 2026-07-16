# SuxOS/.github — shared CI/autonomy pipeline

Reusable GitHub Actions workflows extracted from `colinxs/sux`, phase 1 of the
SuxOS migration (see `sux/docs/knowledge/refactor-runbook.md`). Every
SuxOS repo inherits this pipeline via a thin caller stub instead of copying
1,400+ lines of workflow YAML per repo.

## Repos in this org

- `sux` — the Cloudflare Worker MCP server this pipeline was extracted from.
- `suxrouter` — OpenWrt/ucode router project.
- `sux-fileops` — file-operations tooling.
- `claude-config` — shared Claude Code configuration.
- `suxlib` — SuxOS v2 op-engine library (`@suxos/lib`), no Cloudflare Worker to deploy.
- `.github` — this repo: org profile + the reusable CI/autonomy pipeline.

## The two groups

**Gates** (required checks that block merge):
`ci.yml` · `security-review.yml` · `audit.yml` — secret scanning is
GitHub's native secret-scanning + push-protection (repo Settings → Security), not
a workflow here; the standalone `secret-scan.yml`/`gitleaks` gate was retired.

**Scheduled monitoring** (runs on the caller's schedule/dispatch, opens/refreshes a tracking issue — does not block merge):
`health.yml` (app health) · `pipeline-utilization.yml` (autonomy-pipeline run volume/duration —
a proxy for spend/waste, since actual Claude token usage isn't queryable via the GitHub API)

**Autonomy pipeline** (keeps PRs moving hands-off — native GitHub auto-merge, not a merge
queue; see [docs/design/three-loop-pipeline.md](docs/design/three-loop-pipeline.md)):
`automerge.yml` · `pr-auto-update.yml` · `pr-drain.yml` · `pr-watch.yml` ·
`pr-unstick.yml` · `claude.yml` · `claude-autofix.yml` (job-chained from each caller's
`ci.yml`, not its own caller-stub file — see § `workflow_run` below) · `skill-sync.yml`

**Budget & deep passes** (run directly in THIS repo — not reusables; see
[docs/design/budget-and-cadence.md](docs/design/budget-and-cadence.md)):
`budget-governor.yml` (every 6h: org-wide spend-proxy sweep → per-repo "Autonomy throttle"
issues that scheduled Claude workloads read via the `check-throttle` action — the smarter
successor to the retired binary `budget-guard.yml`) · `deep-audit.yml` (nightly opus pass
over each repo's merged diff — the compensating control for the sonnet per-PR
security-review) · `org-consistency.yml` (weekly opus cross-repo drift + refactor sweep,
files findings into the backlog pipeline).

**Backlog pipeline** (turns latent work into merged PRs — propose → build):
`fixer.yml` (propose work as typed issues) · `issue-build.yml` (select the top-priority open
issues, one builder session over the batch, always ≥1, never waits; PRs auto-merge on
green). The separate Opus `triage` stage, the `confidence:*` taxonomy, and the Claude
`cluster` pass were removed in the
three-loop rework — see [docs/design/three-loop-pipeline.md](docs/design/three-loop-pipeline.md)
(current design) and [docs/design/backlog-pipeline.md](docs/design/backlog-pipeline.md)
(historical). Caller-stub examples below.

**Self-hosted (`self-*.yml`)** — this repo also runs the backlog pipeline on itself:
`self-fixer.yml` · `self-issue-build.yml` · `self-automerge.yml` ·
`self-security-review.yml` are caller stubs that wire `fixer.yml`/`issue-build.yml`/
`automerge.yml`/`security-review.yml` back onto SuxOS/.github, so this repo's own open
issues flow through the same propose → build → automerge pipeline as `sux`/`suxrouter`.
Since this repo ships no app (only reusable workflow YAML), `self-issue-build.yml` gates
on `actionlint` (`self-check.yml`) + `pin-consistency.yml` instead of a Node build/test
trio. Marked TEMPORARY in `self-fixer.yml`'s header — a consciously self-hosted
arrangement, not the long-term shape. `self-pr-auto-update.yml` · `self-pr-watch.yml` ·
`self-pr-drain.yml` complete Loop 3 on this repo too — without them, a second
concurrent bot PR against `.github` flips BEHIND on merge with no rebase/visibility/
drain backstop (issue #189).

`gh workflow list --repo SuxOS/.github --all` shows the org's shared reusable
workflows (`automerge.yml`, `fixer.yml`, `issue-build.yml`, `pr-auto-update.yml`,
`pr-drain.yml`, `pr-watch.yml`, `security-review.yml`) as `disabled_manually`. This
is **by design and harmless**: they were disabled to stop their own direct triggers
from firing on this repo, but `workflow_call`/`uses:` reuse by other repos is
unaffected by that state — disabling a workflow's direct triggers doesn't block
other repos from calling it. Only the `self-*.yml` stubs above need to stay directly
enabled for this repo's own pipeline to run; don't re-enable the shared reusables
here on the strength of `gh workflow list` output alone.

### The three loops → workflows (the resolvable map)

`claude-config`'s `fabric.json` names the pipeline as three loops; this is what each
resolves to here (consumed by the `dispatch`/`orient` tools):

| Loop (fabric slug) | Workflows |
|---|---|
| `collate-build` | `fixer.yml` + `issue-build.yml` |
| `green-merge` | `automerge.yml` |
| `red-rebase` | `pr-auto-update.yml` + `claude-autofix.yml` + `pr-unstick.yml` |

Everything else (`security-review`, `deep-audit`, `org-consistency`, `budget-governor`,
`pr-watch`, `pr-drain`, `health`, `ci`, `audit`) is a required check or a safety net, not
one of the three loops.

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
mirror sux's layout — override the ones that don't fit your repo). Callers
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
# issue-build.yml — select buildable issues, build. Batched cron, NOT a per-issue
# `issues:` trigger — an issue-event stub fans out a session per event during fixer bursts
# (SuxOS/.github#140).
name: Issue build
on:
  schedule: [{ cron: "7 2,8,14,20 * * *" }]
  workflow_dispatch:
jobs:
  issue-build:
    uses: SuxOS/.github/.github/workflows/issue-build.yml@main
    with: { gates-summary: "npm run type-check · npm test · npm run lint" }
    secrets: inherit
```

`scripts/scaffold-caller.sh` generates these stubs (and the others above) directly —
prefer running it over hand-copying, so a caller repo can't drift from the cadence above.

Labels each repo needs once (`gh label create`): `building`, `needs-human`, plus the usual
`automerge` / `hold`. (The `confidence:*`, `triaged`, `queued-for-build`, and `needs-review`
labels were retired in the three-loop rework — issue-build selects/claims directly and
`automerge.yml` no longer reads eligibility labels.)

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
  Auto-applied by `security-review.yml` only on a CONFIRMED critical/high finding — a
  missing/unreadable verdict (the reviewer didn't finish) is an advisory pass, not a hold;
  we'd rather ship and roll back than block merges on a flaky review run. If the pipeline
  looks stuck and it's not obvious whether `hold` (or something else) is why, see
  [docs/runbooks/pipeline-wedged.md](docs/runbooks/pipeline-wedged.md).
- `needs-human` — not safe for unattended handling. `claude-autofix.yml` applies it
  once its retry cap is hit.
- `feature` — net-new feature work; as of #152 this label no longer vetoes auto-merge
  (previously a hard human-only gate). A `feature`-labeled PR auto-merges under the same
  bar as any other — a safe-type title or one of `automerge`/`bug`/`security`/`chore-safe`,
  plus passing CI + security-review — `feature` itself is not one of the eligible labels.
- `chore-safe` — safe refactor/cleanup/docs; one of the auto-merge-eligible labels.
- `keep` — opts a PR out of `pr-drain.yml`'s close-stale sweep (alongside `hold`)
  without blocking any other automation.
- `security` — security fix; auto-merge-eligible like `chore-safe`/`bug`/`automerge`.
- `self-improve` — keeps bot PRs out of `pr-drain.yml`'s close-stale sweep. (It no longer
  gates auto-merge: `automerge.yml`'s trusted-author check was removed in Phase 1, since the
  repos are private — it now arms on `not-draft AND not-hold` regardless of author.)

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

For most event triggers (`schedule`, `pull_request_target`, `issues`, etc.) the caller's
own stub file declares the trigger and then `uses:` the reusable file for the job body —
`workflow_call` can't re-expose those triggers itself.

**`claude-autofix.yml` is the one exception, and it is deliberately NOT wired this way.**
It used to have its own per-caller stub with `on: workflow_run: workflows: ["CI"]`, but
that cross-workflow trigger structurally never fired for a PR-branch CI run (confirmed
live, SuxOS/.github#260 — every historical run across sux/suxrouter/sux-fileops was tied
to `main`, never a PR). It is now `workflow_call`-only, invoked as a **job chained inside
each caller's own `ci.yml`** — no separate stub file, no `workflow_run`:

```yaml
# .github/workflows/ci.yml in a SuxOS caller repo — after the job that runs the gates
jobs:
  check: # (or whatever the gate job is named — lint, test, ...)
    # ... existing steps ...

  autofix:
    needs: [check]
    if: needs.check.result == 'failure' && github.event_name == 'pull_request'
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
    uses: SuxOS/.github/.github/workflows/claude-autofix.yml@main
    with:
      pr-number: ${{ github.event.pull_request.number }}
      head-branch: ${{ github.event.pull_request.head.ref }}
      head-sha: ${{ github.event.pull_request.head.sha }}
      base-branch: ${{ github.event.pull_request.base.ref }}
    secrets: inherit
```

Same-workflow job chaining doesn't have `workflow_run`'s cross-workflow/branch reliability
gap: the PR identity (number/branch/sha) is read straight from the caller's own
`github.event.pull_request.*` at the point the gate job fails, and passed explicitly as
`workflow_call` inputs — no reconstructing it from an asynchronous `workflow_run` event
payload that may never arrive. `github.event_name == 'pull_request'` on the caller's own
job keeps this from firing on a `push`/`merge_group` run of `ci.yml`.

## Two hard-won gotchas preserved from sux (read before editing these files)

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
   security reviews in sux. Always pass `--json-schema` in `claude_args`
   and read the verdict via
   `fromJSON(steps.<id>.outputs.structured_output).<field>` — it's
   cwd-independent.

Full details: `sux/docs/knowledge/auth-github-ci.md`.
