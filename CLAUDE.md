# CLAUDE.md — working in SuxOS/.github

This repo is the **shared CI/autonomy pipeline** for every SuxOS repo — reusable
`workflow_call` YAML, not app code. Read [README.md](README.md) first; it has the
full workflow inventory, auth split, caller-stub pattern, and gotchas. This file is
just the rules for editing it. Universal cross-project rules live in
`~/.claude/CLAUDE.md`.

## The one thing that matters: these files are shared

Every SuxOS repo inherits these workflows via `uses: SuxOS/.github/.github/workflows/X.yml@main`.
A change here is a change to every caller repo's CI/automerge/backlog pipeline
simultaneously — there's no per-repo blast-radius limit. Before editing:

- Check `inputs:` defaults are still sane for every known caller (`sux`, `suxrouter`,
  `claude-config`, `suxlib`) — a default that fits `sux` may silently break a
  caller with a different layout (e.g. no Worker to dry-run-deploy). Keep this list in
  sync with the org repo list in README.md as new repos join.
- Don't add a new required secret/var without updating the "Required secrets/vars"
  list in the README — a caller repo missing it fails opaquely.
- `workflow_call` cannot re-expose event triggers (`schedule`, `issues`,
  `workflow_run`, etc.) — those stay in each caller's stub. Don't try to move them
  here; see README § `workflow_run`.

## Auth — unified on the subscription token

Every Claude workflow, including `security-review.yml`, authenticates with
`CLAUDE_CODE_OAUTH_TOKEN` (Pro/Max subscription). This was consolidated by explicit
decision. **Accepted risk:** `security-review.yml` is a required merge gate, so if the
shared subscription pool exhausts, the gate can't run and the merge queue jams for
everyone. It was previously held on the metered `ANTHROPIC_API_KEY` to avoid exactly
that — if jams appear, revert `security-review.yml` to `anthropic_api_key`. See README
§ Auth and `docs/design/backlog-pipeline.md`.

## Before merging a workflow change

Test against a real caller if the change touches trigger conditions, secrets, or
`if:` logic — YAML workflow bugs don't show up in type-check/lint, only in an
actual run. Prefer landing behind a caller repo's `workflow_dispatch` smoke test
before it goes live on `schedule`/`issues` triggers across the whole org.

A composite action's embedded `run:` shell block is directly unit-testable without
a live `gh`: extract it with `yq -r '.runs.steps[] | select(.id == "X") | .run'
action.yml`, then execute it via `bash -c "$extracted"` with a fake `gh` shim
prepended to `PATH` and the action's `inputs:` set as env vars. This tests the
actual shipped logic (no drift from a hand-copied stand-in) and needs no test
framework — see `scripts/test-scaffold-caller-regression.sh` for worked examples
(pr-eligibility, upsert-tracking-issue, flood-guard, check-throttle).
