# Live-fire acceptance harness for reusable-workflow PRs — scoping pass

> **Status:** design/scoping only — no code in this doc.
> **Trigger:** #483. Per this repo's own established precedent (see
> `2026-07-18-epic-decomposition-design.md`, `2026-07-18-value-ranking-selection-design.md`),
> an `effort:large` issue whose own body asks for a scoping pass ships this doc as its
> first buildable slice instead of being REDUCE-dropped every builder session.

## 1. Problem

CLAUDE.md states outright that "YAML workflow bugs don't show up in type-check/lint,
only in an actual run." `self-check.yml`'s gate — actionlint plus the
`scripts/test-*.sh` shell/JS-extraction scripts — never runs a real `workflow_call`
invocation with live triggers, `if:` conditions, and secrets end-to-end. Every
mitigation today is developer discipline ("prefer landing behind a caller repo's
`workflow_dispatch` smoke test"), and the resulting production-only-bug tail is long
and self-documented in this repo's own history: `workflow_run` structurally never
firing for PR-branch CI (#260), the reusable-workflow checkout defaulting to the
caller repo so a script 404s and a fallback masks it as fail-closed (#428), `bash -e`
semantics differing between the local extraction harness and the real runner
(#404/#411), and a diagnostic string phantom-tripping an allowlist gate (#443). Six-plus
instances of the same structural gap, not one-off mistakes — because "a change here is
a change to every caller repo's CI/automerge/backlog pipeline simultaneously" (README.md),
there's no blast-radius limit to catch these before they ship to every caller at once.

## 2. What already half-solves this

This repo already dogfoods itself: `self-fixer.yml` / `self-issue-build.yml` /
`self-security-review.yml` / etc. are caller stubs wired back onto `SuxOS/.github`
(README.md § Self-hosted). That proves the *mechanism* of a caller repo calling this
repo's own reusable workflows works end-to-end. What nobody has done is extend that
pattern into a **PR-time** gate that fires against the PR's *own ref* instead of
`@main` — every `self-*.yml` stub today hardcodes `@main` in its `uses:` line
(confirmed: `self-issue-build.yml:21`, `self-security-review.yml:18`), so none of them
would ever exercise an unmerged change.

**Note on #490.** #490 independently proposes "one small, dedicated, low-stakes canary
repo" for a *different* purpose — a post-merge, continuously-scheduled chaos-test of
`caller-conformance.yml`'s detect/remediate loop specifically. That issue's own body
already flags itself as distinct from this one (pre-merge, general-purpose acceptance).
The two should very likely **share the same provisioned canary repo** (one App install,
one set of canonical stubs) rather than each standing up its own — worth resolving
which issue provisions the repo first and having the other depend on it, instead of
building two canaries in parallel.

## 3. Concrete plan

1. **Canary repo.** A dedicated, low-stakes repo (e.g. `SuxOS/pipeline-canary`) with
   its own GitHub App install (least-privilege, scoped only to itself — not the shared
   `SUX_BOT_APP_ID`, so a canary compromise or runaway loop can't touch real repos) and
   no real backlog at stake. It carries caller stubs shaped like `self-issue-build.yml`
   et al., but triggered by `workflow_dispatch` only (never `schedule`/`issues` — this
   repo's own `workflow_call` rule already forbids re-exposing those triggers from a
   reusable workflow, and a dispatch-only trigger is exactly what a gate needs to fire
   on demand).
2. **Ref indirection — the unproven step.** Each canary stub's `uses:` line needs to
   resolve to the PR's ref (`refs/pull/<N>/head` or its head SHA) instead of `@main`.
   Whether GitHub Actions permits an expression (e.g. `${{ inputs.pipeline-ref }}`)
   in a reusable-workflow `uses:` ref is genuinely uncertain from reading this repo's
   own workflows alone — every existing `uses: SuxOS/.github/...@main` in this org is a
   static string, so there's no precedent here to confirm or rule it out. **This must be
   proven directly, against one workflow, before any of the rest of this plan is worth
   committing to** — hence phase (3) below being its own standalone step rather than
   folded into the canary stand-up. If dynamic `uses:` refs turn out unsupported, the
   fallback is a wrapper job that checks out the PR ref manually and invokes the
   workflow's steps inline (losing the clean `uses:` call, gaining a maintenance
   burden closer to a copy than a reuse) — worth knowing early, not after phases 1-2
   are sunk.
3. **Prove it on one workflow.** Pick the cheapest, most self-contained reusable
   workflow to validate the ref-indirection mechanism (`pr-watch.yml` is read-only —
   no mutation risk if the mechanism misfires — and small, making it a better first
   target than e.g. `issue-build.yml`, which spends real Claude budget per run).
4. **Wire it as an async-polling gate.** A new workflow on `SuxOS/.github` PRs
   (`pull_request`, paths `.github/workflows/**` and `.github/actions/**`) that
   dispatches the canary's stub via `gh workflow run --ref <canary-main>
   -f pipeline-ref=<pr-head-sha>`, then polls (`gh run list`/`gh run watch`, same
   idiom `budget-governor.yml` and `pr-unstick.yml` already use for cross-run polling)
   until the dispatched run completes, and asserts on its real outcome — not a
   simulated one. Start **advisory only** (non-required check) until its false-positive/
   false-negative rate is measured; promote to a required gate only after that.
5. **Expand coverage/cadence based on measured cost.** Real `workflow_dispatch` runs
   cost real Actions minutes, and any workflow in the `issue-build.yml`/`fixer.yml`
   family costs real Claude spend per invocation — gating on `issue-build.yml`
   specifically needs either a zero-Claude-spend dry-run mode (doesn't exist today) or
   a deliberate, measured budget line, not a blanket "run everything on every PR."
   Scope which of this repo's ~15 reusable workflows are worth the live-fire cost
   before wiring all of them; the six-plus-bug history in §1 is not evenly distributed
   across all of them (`security-review.yml`, `issue-build.yml`, and the
   `pr-drain`/`pr-watch`/`pr-unstick` trio account for most of the cited incidents).

## 4. Why this PR doesn't build it

This is a new repo + a new App install + an unproven GitHub Actions mechanism + a new
polling gate + a real-spend cost tradeoff — a multi-week, multi-repo effort by any
reading, and by this repo's own precedent (see the epic-decomposition doc's §3, same
"clustering anti-pattern" lesson from `three-loop-pipeline.md` §8) attempting it in one
30-minute build session risks shipping a half-wired mechanism that later steps depend
on and that nobody can trust. The issue's own suggested phasing (scoping doc → stand up
canary + stubs → prove ref-indirection → wire as gate → expand) is right-sized as
independently buildable, independently droppable slices; §3 above is that same phasing
re-derived with the concrete uncertainty (§3.2) called out explicitly so the next
builder doesn't have to rediscover it.

## 5. Suggested follow-up issues (small enough to build individually)

- Stand up the canary repo + minimal `workflow_dispatch`-only stub for one cheap,
  read-only reusable workflow (`pr-watch.yml`) — small, no ref-indirection yet (pinned
  to `@main`, just proving the App install + stub shape works standalone).
- Prove or disprove parameterizing a reusable-workflow `uses:` ref via an expression
  (§3.2) — small, single-workflow spike; the answer determines whether phase 4 is a
  clean `uses:` dispatch or a manual-checkout wrapper.
- Wire the async-polling gate against the one proven workflow, advisory (non-required)
  only — medium, depends on the previous two.
- Measure false-positive/false-negative rate and real Actions-minute/Claude-spend cost
  over a trial period; use that to decide which additional workflows (from §3.5's
  candidate list) are worth adding and whether to promote the gate to required —
  depends on the advisory gate having run for a while first.
