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

This repo's own gate is `self-check.yml`: **actionlint** (which also runs
shellcheck over embedded `run:` blocks) plus the `scripts/test-*.sh` invariant
scripts (five as of #307/#308) — run those locally, not `yamllint`. `yamllint` is
on the runner but its default 80-col config flags nearly every pre-existing line
here and is *not* the gate. Each script is wired into `self-check.yml` by explicit
name, not a glob, so adding a new one means adding its step there too.

Nothing gates `grafana/*.json` beyond JSON syntax — no PromQL linting — so reason
dashboard-query edits by hand (extract each `expr` and sanity-check it against
sample series). `scripts/test-dashboard-queries.sh` (#339, wired into
`self-check.yml`) now gates the deterministic slice: every `expr`'s `suxos_*`
metric/label reference must exist in the surface `fabric-health.yml` emits, and an
age-span subquery window must stay strictly wider than its threshold (#320) — but
it is NOT a full PromQL linter, so the by-hand reasoning still stands for anything
it can't check (e.g. aggregating an emit-only-when-disabled series, #291). Fabric-health collectors follow a **collection-integrity contract**
(#305): a `gh` query must never fail-silent to a healthy-looking zero — emit
`suxos_collection_ok{repo,collector}` (0 on error) and gate any derived signal that
would otherwise read green (esp. `backlog_zero`, which feeds the 7-day DoD streak).

A composite action's embedded `run:` shell block is directly unit-testable without
a live `gh`: extract it with `yq -r '.runs.steps[] | select(.id == "X") | .run'
action.yml`, then execute it via `bash -c "$extracted"` with a fake `gh` shim
prepended to `PATH` and the action's `inputs:` set as env vars. This tests the
actual shipped logic (no drift from a hand-copied stand-in) and needs no test
framework — see `scripts/test-scaffold-caller-regression.sh` for worked examples
(pr-eligibility, upsert-tracking-issue, flood-guard, check-throttle). When capturing
that output to assert on `::error::`/`::warning::`/`::notice::` text, remember those
are plain `echo`s to stdout (the runner UI parses them, but they aren't stderr) — a
`2>&1 >/dev/null` stderr-only capture silently discards them; use `2>&1` (merged) or
plain stdout capture instead.

`.github/actions/gh-list-exhaustive` (#396) is the shared helper for the
"`gh ... list --limit N` then client-side filter" undercount bug class fixed ad hoc
at least six times (#18, #247, #344, #345, #350, #366) before this: it pages until
it sees the true end of the list or fails loud instead of returning a
`--limit`-capped result. Prefer it over a new bespoke bounded list call. A composite
action CAN call another composite action as a `uses:` step (not just a workflow
calling one) — reference it by the full `SuxOS/.github/.github/actions/X@main` form
(a relative path won't resolve in a caller repo's checkout), and add
`continue-on-error: true` on that step if the calling action has a fail-open
contract, since a failed nested action otherwise halts the parent; see
`.github/actions/flood-guard/action.yml` for the reference wiring. Only flood-guard
is migrated so far — check-throttle, fabric-health, pr-watch, pr-unstick/
detect-unreachable-checks, and budget-governor still have their own (already
working) bespoke mitigations and are deliberately left as separate future
migrations rather than churned in one pass.

`actionlint` does NOT lint `github-script` `with.script:` JS — that JS is a blind spot
in the gate, so a syntax error there ships silently. Validate any such block with
`node --check <(yq -r '.jobs.J.steps[]|select(.id=="X").with.script' wf.yml)`, and
unit-test a self-contained slice of it by extracting the region with `awk` between
anchor comments and running it via `new Function(...)` with fixtures injected — see
`scripts/test-issue-build-prereq-gating.sh` (tests issue-build's select heuristic this
way, same no-drift principle as the shell-block extraction above).
