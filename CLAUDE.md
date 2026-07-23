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
  `claude-config`, `suxlib`, `suxdash`, plus the cold-tier `suxos-net`/`nix`) — a default
  that fits `sux` may silently break a
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
§ Auth and `docs/design/archive/backlog-pipeline.md` (historical, archived).

## Before merging a workflow change

Test against a real caller if the change touches trigger conditions, secrets, or
`if:` logic — YAML workflow bugs don't show up in type-check/lint, only in an
actual run. Prefer landing behind a caller repo's `workflow_dispatch` smoke test
before it goes live on `schedule`/`issues` triggers across the whole org.

This repo's own gate is `self-check.yml`: **actionlint** (which also runs
shellcheck over embedded `run:` blocks) plus the `scripts/test-*.sh` invariant
scripts (ten as of #413; check `.github/workflows/self-check.yml` for the current
count/list, don't trust a hardcoded number here) — run those locally, not
`yamllint`. `yamllint` is
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

`scripts/test-no-new-gh-list-limit.sh`'s allowlist gate is a plain `grep` over
`.github/workflows`/`.github/actions` line content, not a real invocation parser — an
`echo "::error::..."`/log message that happens to mention a workflow's own `gh ...
list` call together with `--limit` on the same line trips it as a phantom "new
bespoke call site", same as an actual new call would (#443). Word any such
diagnostic string to avoid that exact co-occurrence, or add it to the allowlist,
rather than assuming only real invocations can fail this gate.

`actionlint` does NOT lint `github-script` `with.script:` JS — that JS is a blind spot
in the gate, so a syntax error there ships silently. Validate any such block with
`node --check <(yq -r '.jobs.J.steps[]|select(.id=="X").with.script' wf.yml)`, and
unit-test a self-contained slice of it by extracting the region with `awk` between
anchor comments and running it via `new Function(...)` with fixtures injected — see
`scripts/test-issue-build-prereq-gating.sh` (tests issue-build's select heuristic this
way, same no-drift principle as the shell-block extraction above).

When extracting a `run:` block per the above, invoke it as `bash -e -c "$extracted"`,
not bare `bash -c`: the runner's actual default shell for `run:` steps is
`bash --noprofile --norc -eo pipefail {0}`, so `-e` is already active on every real
run even when the step's own script only does `set -uo pipefail` (that omission
doesn't turn `-e` off — it was never the script's to unset). A bare `bash -c` harness
starts with no flags at all, so it silently misses any bug that only manifests under
errexit (#404: an unguarded no-match command substitution killed the real step but
passed locally under `bash -c`); `bash -e -c` reproduces the real semantics regardless
of what the extracted script's own `set` line says (#411).

A plain `var=$(pipeline)` assignment is itself a simple command, so under `-e` it aborts
the instant the substitution's own exit status is non-zero — with `pipefail`, that's true
whenever the pipe's rightmost *failing* stage (e.g. a `grep` with no match feeding `sort`/
`head`, which then both exit 0) is non-zero, even though every stage after it "succeeds".
A `[ -n "$var" ] || continue` guard written on the *next* line never gets a chance to run;
the assignment already killed the step (#404 — budget-governor's rate-limit scan aborted
on every ordinary failed run, since a log with no `five_hour` marker is the exit-1 case).
Guard the assignment itself, e.g. `var=$( { pipeline; } || true)`, not just its result.

A reusable workflow's `run:` step that shells out to `scripts/X.sh` only works when the job's
checkout actually put that file at that cwd. `workflow_call`'s default Checkout step (no
`repository:` override) checks out the CALLER repo, not SuxOS/.github — so a bare
`bash scripts/X.sh` silently 404s in every caller and any `|| echo <fallback>` around it masks
the failure as a legitimate result (#428: security-review.yml's no-verdict classifier always
fell back to `fail-closed` in every caller repo this way). If a reusable step needs a script that
lives only in this repo, add an explicit second `actions/checkout@... with: {repository:
SuxOS/.github, ref: main, path: .suxos-ci}` and call it from that subpath — don't sync copies
into callers.

`gh pr list --json ...,files` fetches each matched PR's full changed-file list, not a cheap
flat field — fine at pr-drain.yml's current `PR_LIMIT` default (200) against this org's actual
open-PR counts (low single digits per repo), but check the added latency/rate-limit cost
before reaching for `files` on a list call whose limit could realistically climb into the
hundreds (#437 added it to pr-drain's DIRTY-CONFLICT sweep for a diagnostic-only sibling
hot-file-overlap check).

An `effort:large` issue whose own body says it needs "a design/scoping pass first" doesn't have
to just get REDUCE-dropped every time a builder session hits it (#439 was dropped once already
for this exact reason before being scoped). Shipping a `docs/design/YYYY-MM-DD-*.md` scoping
doc — re-deriving a concrete plan, sizing it into small independently-buildable follow-up
slices, explaining why this session doesn't build it all at once — is a legitimate, gate-passing
build for that issue (`Closes #n` on the doc commit), not a dodge; see
`docs/design/2026-07-18-epic-decomposition-design.md` (#433) and
`docs/design/2026-07-18-value-ranking-selection-design.md` (#439) as the two precedents. Beats
leaving it to rot as an indefinite drop, and gives the next build (or a human) something durable
to act on instead of re-deriving the same plan from scratch a third time.

A concurrency cap that counts in_progress/queued WORKFLOW RUNS silently undercounts once a
run finishes but leaves behind a durable artifact (an open PR) that keeps mattering after the
run itself disappears from that list — the cap then lets new work dispatch past its own
intended ceiling (#434: issue-build.yml's `requeue` job capped `parallel-batches` against
in-flight runs only, so once a batch's `build` job finished and opened a PR, the run stopped
counting even though the PR stayed open for hours, and requeue kept dispatching more batches
— 7 concurrently-open builder PRs piled up and mutually DIRTY-conflicted on shared hot files).
When a cap is meant to bound "how many X are outstanding," count the outstanding X directly
(here, open PRs matching the builder's branch pattern) alongside — via `max()`, not sum, to
avoid double-counting the common case — any in-flight run that hasn't produced one yet. And
gate that outstanding-artifact count by the SAME trust predicate its siblings use (`isTrusted`):
counting ALL open PRs by branch-name prefix alone lets an untrusted fork PR named
`bot/issue-build-*` inflate the cap and stall the autonomous drain — a cheap unauthenticated
DoS on shared CI (the #193 decoy-PR class). A count that feeds an automation gate must apply
the author gate, not just a name match.

A composite action's `uses:` step cannot be invoked from inside a bash `for`/`while` loop in a
`run:` block — GitHub Actions steps are static, not callable mid-script. When a mutating sweep
needs the SAME shared check logic on every loop iteration (e.g. `gh pr view` + a hold/keep
re-check right before acting, #461), wrapping it in a composite action only gives you a `uses:`
entry point for OTHER workflows shaped as one-step-per-item (e.g. a matrix job). For the loop
itself, check out this repo (`actions/checkout@... with: {repository: SuxOS/.github, ref: main,
path: .suxos-ci}`, same private-repo token pattern as the reusable-workflow-script gotcha above)
and `bash .suxos-ci/.github/actions/<name>/check.sh "$item"` directly inside the loop — same
file the composite action wraps, so there's still exactly one copy of the logic, just two entry
points into it. See `.github/actions/pr-live-hold-check` + its two call sites in pr-unstick.yml.

A REQUIRED status check's terminal Gate step must run unconditionally (`if: always()`, no
trailing `&& steps.X.outputs.go == 'true'`) and treat any upstream skip condition (a missing
secret, a preflight failure) as an explicit fail-closed branch inside that same step — GitHub
scores a *skipped* step as non-blocking, so gating the Gate step itself on an upstream flag lets
the whole job report SUCCESS with nothing actually checked (#507: security-review.yml's Preflight
set `go=false` on a missing `CLAUDE_CODE_OAUTH_TOKEN`, which skipped Gate too and merged PRs
completely unreviewed). This is distinct from an ordinary best-effort workflow's own internal
`go` skip (e.g. claude-autofix.yml's cap/gate checks) — those are fine to skip on, because nothing
downstream treats that job's SUCCESS as "reviewed" the way a required check's is.

A job whose body is a `uses:` reusable-workflow call cannot ALSO carry its own `steps:` —
so a caller stub that wants to derive a `with:` input from a file in this repo (e.g. the
`.github/managed-repos.json` repo list, #499) needs a separate job that checks out, computes,
and exposes an `outputs:`, with the reusable-calling job pulling it via `needs.<job>.outputs.x`
— it can't just add a step ahead of its own `uses:` line. `pin-consistency.yml`'s
`managed-repos` job and `self-fabric-health.yml`'s `load-repos` job are the reference shape.

A builder session's own `gh auth status` token (this job's default token — not a workflow's
minted `mint-app-token` App token) is scoped to the single repo the job runs in (`SuxOS/.github`)
— `gh repo view SuxOS/sux` / `gh pr view N --repo SuxOS/claude-config` fail with "Could not
resolve to a Repository," which reads like the repo doesn't exist rather than like a permissions
error. This has repeatedly blocked diagnosing incidents reported against caller repos purely
because the session can't read that repo's PR/issue history (#484, #492, #506 — #484 alone was
dropped 3 times for exactly this). There's no in-repo workaround: escalate to a human with
broader `gh` access for that one lookup, or reason from evidence already pasted into the issue
body/comments rather than guessing at a live-only bug in code you can't observe.

`gh issue list --json <fields>` does NOT support `authorAssociation` (or a numeric author id) —
`gh issue list --json number,authorAssociation` errors "Unknown JSON field," even though
`gh pr list --json ...,authorAssociation` and the raw REST endpoint both expose it fine. A bash
collector that needs an issue's trust info (e.g. the isTrusted predicate, #186/#193) can't get it
from `gh issue list` at all — use `gh api -X GET "repos/OWNER/REPO/issues?state=open&per_page=100"
--paginate --slurp` instead (exhaustive by construction, no separate cap-hit check needed;
`--slurp` always wraps pages as an array-of-arrays — even a single empty page comes back `[[]]`,
not `[]` — so flatten with `jq '(add // [])'`, the `// []` guarding a shim/edge-case bare `[]`
input under `set -e`), then drop `.pull_request != null` entries since the raw issues endpoint
also returns PRs. See fabric-health.yml's backlog collector (#521) for the reference shape.

`scripts/test-dashboard-queries.sh`'s metric-to-collector pairing (#391) finds each Grafana
metric's real `suxos_collection_ok` gate by scanning `fabric-health.yml` for `jq -r` ...
`<<< "$status"` blocks, and it does this with a dumb line-based state machine, not a real
parser: ONE `jq -r` trigger line opens a block that stays open across everything until the
NEXT line containing the literal `<<< "$status"`, even across unrelated steps. Inserting new
`run:` code anywhere between the job's first `jq -r` call (early, in the #475 self cross-run
fetch) and the Grafana-push step's first real `<<< "$status"` line silently re-merges that
whole span into one phantom block; if your new code happens to also contain a
`.collection.<name> == 1`-shaped comparison anywhere in that span, its collector name gets
mis-attributed to every metric the corrupted block touches (#554). Fix is on your side, not
the test's: avoid the exact `\.collection\.[a-z_]+\s*==\s*1` shape in code landing in that
span — e.g. write `!= 0` instead of `== 1` — rather than reworking the scanner.

A NESTED command substitution inside arithmetic expansion — `total=$(( total + $(cmd) ))` —
is a distinct trap from the plain `var=$(pipeline)` case above: per POSIX, a simple command
that's only variable assignments takes the exit status of the last command substitution
performed while building them, so a failing/erroring `cmd` inside the `$(( ))` kills the
whole assignment under `-e` even though the arithmetic itself never "fails" (unlike a bare
`((expr))` *command*, whose own well-known zero-is-failure gotcha this is easy to conflate
it with — different mechanism, same abort-the-step outcome). Pull the inner substitution
into its own `var=$(cmd)` line first, then do plain arithmetic on the two variables
(`fabric-health.yml`'s epic reconciler, #471, hit this while summing per-repo child-issue
counts inside a loop).

Before building a batch, check for a prior attempt on the SAME issue numbers that never
merged: `gh pr list --state closed --search "Closes #N"` (or `git log --all --oneline` for
the issue number/title) can turn up a closed-DIRTY or otherwise-abandoned builder PR whose
commit still exists in git history (nothing garbage-collects it just because the PR closed).
`git cherry-pick -n <that commit>` onto the current branch and resolving the — usually
small — conflicts from main having moved on is often far cheaper than re-deriving the same
implementation from scratch, and lets you focus the session's turns on re-verifying gates
and fixing whatever the earlier attempt's own security-review/self-check findings flagged
(this is how #469/#470/#471/#540/#541 landed together: salvaged from #611, a DIRTY-closed
PR building the identical batch, with its one real high-severity finding — an unvalidated,
model-authored cross-repo issue-filing destination in fixer.yml's epic step — fixed on top).

A `scripts/test-*.sh` that extracts a workflow's `run:` block via `awk '/start-pattern/,/end-
pattern/'` anchored on the LITERAL closing text of a jq/shell construct (not a stable marker
comment) breaks silently the moment that construct grows a field after the anchor — the range
either never closes or captures the wrong span, and the failure reads as a jq syntax error, not
an obviously-related diff (#648: adding a field to fabric-health.yml's Loki-rollup jq object
moved its closing `}` past `test-fabric-health-sweep.sh`'s `pr_stuck: \$stuck_total\}` end-
anchor). When you add a field to a `run:` block that a sibling test extracts this way, update
that test's anchor (and any new `--argjson`/`--arg` the extracted snippet now references) in
the same commit — `grep` the test directory for the block's distinctive text before assuming
an edit to a workflow's `run:` block is self-contained.

A `jq` filter embedded in a `run:` block is itself wrapped in a bash SINGLE-quoted string
(`jq '...'`) — a stray apostrophe inside a `#`-comment line WITHIN that jq program (e.g. "the
current run's own status", "today's sample") silently closes the outer bash quote early, and
everything after it is parsed as shell syntax instead of jq. The failure shows up far from the
apostrophe itself — a `syntax error near unexpected token '('` on some later jq operator line —
and every YAML/jq linter this repo runs (actionlint's embedded shellcheck, `yaml.safe_load`)
passes clean, since the YAML and the jq text are each individually well-formed; only running the
actual extracted `run:` block (`bash -n`, or a `scripts/test-*.sh` that exercises it) catches it.
Write jq comments without apostrophes, or re-word to avoid one, rather than trying to escape it.
