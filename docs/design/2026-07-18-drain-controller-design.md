# Mechanized drain controller — scoping pass

> **Status:** design/scoping only — no code in this doc.
> **Trigger:** #456. Same shape of ask as #433 (multi-repo epic decomposition) and #439
> (value-ranking selection), scoped the same way in
> `docs/design/2026-07-18-epic-decomposition-design.md` and
> `docs/design/2026-07-18-value-ranking-selection-design.md`: re-derive a concrete plan,
> size it into independently-buildable slices, and commit the plan so it survives issue
> closure instead of being lost (see the epic doc's §4 for the failure mode this guards
> against).

## 1. Problem

Three pieces of telemetry/control already exist in isolation, and nothing wires them
together:

- `fabric-health.yml` computes per-repo `backlog`/`workflow_red`/`collection` and uploads
  it as the `fabric-status` artifact (`fabric-health.yml:270-288`, upload step ~line 406) —
  "ground truth", per its own step name, but read by only one consumer today (see below).
- `budget-governor.yml` runs a real token-bucket simulation
  (`opus_avail_min`/`total_avail_min` -> `level: green|yellow|red`,
  `budget-governor.yml:160-207`) and writes it into a per-repo "Autonomy throttle" tracking
  issue. `check-throttle` (`.github/actions/check-throttle/action.yml`) reads that single
  `level:` line as a **binary go/no-go** — issue-build defers entirely at red
  (`issue-build.yml:188`), nothing today reads it as a dial.
- `issue-build.yml`'s throughput knobs — `max-issues` (default 3), `effort-budget`
  (default 6), `parallel-batches` (default 2) — are static `workflow_call` inputs baked
  into each caller's cron stub (`issue-build.yml:47-93`). The `requeue` job already scales
  *dispatch count* dynamically within the `parallel-batches` ceiling ("sized against
  remaining backlog / effort-budget", `issue-build.yml:79-84,971-`), but the ceiling itself
  and the per-batch size never move.

Meanwhile the live #357 tracking issue shows a human/agent hand-deriving real
proportional-integral math every cadence check-in — `merged_rate`, `setpoint`, `error`,
`integral_error`, `output=clamp(round(Kp*error + Ki*integral), 0, 4)` — in issue-body
prose, every single update. That arithmetic is a strong, proven signal (see §2.1) sitting
nowhere but a human's working memory each cycle.

Separately, #452 (closed, merged in eeec93c) already built a cross-workflow read: `select`
in `issue-build.yml` now fetches `fabric-status.json` from fabric-health's latest run
(fail-soft, `issue-build.yml:173-280`) and exposes it as `spine_*` job outputs — but
**nothing consumes those outputs yet** ("Not yet consumed by the pack/sort logic" per
eeec93c's own commit message). That plumbing is a gift to this design: the hard
cross-workflow-artifact-fetch part is already done and live.

## 2. Concrete plan

### 2.1 Formula — re-derived from #357's own proven live usage

The #357 soak log (runs 16:15Z–17:17Z, 2026-07-18) shows this exact math applied
correctly across four consecutive intervals, including one where the raw output was
*deliberately overridden* — that override is itself a design input (§2.4). Reconstructing
the constants from the log's own worked arithmetic:

```
merged_rate     = merged_prs_in_window / window_hours
setpoint        = open_issue_count / TARGET_DRAIN_HOURS      # log used 48
error           = setpoint - merged_rate
integral_error  = clamp(prior_integral + error, 0, INTEGRAL_CAP)   # log used cap 20, floor 0
output          = clamp(round(Kp * error + Ki * integral_error), 0, OUTPUT_CAP)  # Kp=1, Ki=0.2, cap 4
```

Verified against the log's own numbers: `error=2.65, integral=4.92 -> round(1*2.65 +
0.2*4.92) = round(3.63) = 4` ✓; `error=-1.0, integral=0 -> round(-1.0) clamped to 0` ✓.

**This spec is per-repo, not org-wide.** #357's manual log computes `merged_rate`/`setpoint`
across the whole 7-repo fabric because a human reasoning about overall drain state
naturally looks at the aggregate. But the thing this controller actually tunes
(`issue-build.yml`'s throughput knobs) is a `workflow_call` invoked separately per caller
repo, each with its own cron stub and its own backlog. The formula above must run once per
repo, against that repo's own `backlog`/`merged_prs_in_window`, or a busy repo's real drain
need gets diluted into a fabric-wide average and a quiet repo gets an unwarranted boost.

**New signal needed:** `merged_prs_in_window` does not exist anywhere today.
`fabric-status.json` tracks open-PR counts (`open`/`red`/`stuck`, `fabric-health.yml:132-147`)
but never merged counts. Add one query to fabric-health's existing per-repo loop:
`gh pr list --repo "$slug" --state merged --search "merged:>=<cutoff>"` (count only,
same collection-integrity contract as the existing collectors — a failed query must set
`collection_ok=0` for that repo, never read as a healthy zero, per the repo's own
collection-integrity rule cited in this file's CLAUDE.md).

**Window size — learn from the log's own visible pain point.** fabric-health runs every
15 minutes (`self-fabric-health.yml:12`). The #357 log shows a human twice having to
*override* the raw PI output because a 14-23 minute sampling window was too noisy
("one 14-min zero-merge interval right after 78 merges/day is bursty-gate measurement
noise, not a persistent deficit") — sampling every fabric-health run would mechanize that
same noise, not fix it. Use a wider trailing window for `merged_prs_in_window` (candidate:
1-2 hours, an order of magnitude past the 15-min run cadence) so a single quiet run doesn't
swing the controller the way it swung the human's raw number.

### 2.2 State — the integral term needs to persist across runs

`integral_error` is a running sum; each fabric-health run needs the *previous* run's value
plus how much time elapsed. Reuse the exact pattern #452 already built and merged, just
pointed at fabric-health's own run history instead of a different workflow's: fabric-health
downloads *its own* previous run's `fabric-status.json` artifact (`gh run list --workflow
self-fabric-health.yml --limit 2`, then `gh run download` the prior one — same fail-soft
shape as `issue-build.yml:226-280`), reads back the previous `integral_error` and
`checked_at` timestamp per repo, and computes the new value from there. No new
infrastructure class, no database, no second artifact — same self-contained
snapshot-carries-state shape the token-bucket sweep already uses ("no new persisted state:
… replayed fresh each run from the same event list", `budget-governor.yml:14-15`).

### 2.3 What the output actually drives — and why not `max-issues`/`effort-budget`

#456's own text proposes writing a `max-issues`/`effort-budget` override. Re-deriving
against what already exists: `requeue` (`issue-build.yml:971-`) *already* dynamically
decides **how many** parallel batches to dispatch, "sized against remaining backlog /
effort-budget", bounded by the static `parallel-batches` ceiling (default 2). The #357
log's own semantics for `output` are "N *extra agents*" — a **count of additional build
sessions**, which maps directly onto that existing ceiling, not onto per-batch sizing.
Feeding the controller's output into `max-issues`/`effort-budget` instead would make
`requeue`'s own backlog-proportional dispatch logic redundant with (and potentially
fighting) a second backlog-proportional mechanism computing batch *size*. The more
surgical target is: **the controller's output becomes the `parallel-batches` ceiling for
that repo's next scheduled run**, leaving `max-issues`/`effort-budget` (today's static
per-batch sizing) untouched. This reuses `requeue`'s existing "spill more work in when
backlog is high" logic instead of duplicating it in a new place.

### 2.4 Composing with budget-governor's headroom signal (#456's other named input)

The #357 log shows the human *overriding* the raw PI output during a live five-hour
rate-limit stall, reasoning that "the bottleneck is the SERIAL security-review gate /
shared Claude budget, not build-agent count — spawning more just piles WIP behind an
unmovable gate." That reasoning is exactly the depth-vs-selection distinction the
value-ranking score spec already codifies for a different signal
(`docs/design/2026-07-18-value-ranking-score-spec.md` §4: "low headroom -> lean toward
cheap/thin work … never a reason to skip"). Same principle here, inverted: budget headroom
should **dampen the controller's output, never invert its sign** — i.e. multiply the raw
`output` by a headroom fraction (from `budget-governor.yml`'s already-computed
`opus_avail_min`/`total_avail_min`) so the ceiling is scaled toward the *current* static
default as headroom shrinks, floor at the static default (never push the ceiling *below*
what a human already configured). `check-throttle`'s existing `defer-at: red` already
covers the true stop condition (issue-build doesn't run at all at red); the dampening only
needs to handle yellow, where builds still run but shouldn't be told to run *more* of them
into a tightening budget.

### 2.5 Write/read path — extend the artifact, not the throttle issue

#456 suggests writing the override "into the same channel `check-throttle` already
reads" (the per-repo "Autonomy throttle" tracking issue). Re-deriving this against the
actual code turns up a real conflict: `budget-governor.yml` already fully replaces that
issue's body every 6 hours (`upsert-tracking-issue`, `update-mode: replace`,
`budget-governor.yml:367-`) on its own schedule, independent of fabric-health's 15-minute
cadence. A second workflow writing its own full-replace body to the same issue on a
different schedule means whichever wrote most recently wins and the other's write is
silently lost within one cycle — the exact multi-writer clobber this repo's tracking-issue
convention has never had to handle before now. `check-throttle`'s own docstring is also
scoped to a binary decision ("go"/"level"), not a numeric dial, so overloading it conflates
two different consumers' concerns.

The cleaner path: add the computed `recommended_parallel_batches` (per repo) as a **new
field in `fabric-status.json` itself** (fabric-health.yml already owns writing that
artifact single-threaded, no second writer). Read side: extend the spine-fetch step
`issue-build.yml` already has (`issue-build.yml:226-280`, built by #452) to also parse this
new field — it is already fetching the same artifact for `spine_backlog_total` etc., so
this is one more `jq` extraction in an existing fail-soft block, not new plumbing. `requeue`
then uses it (fail-soft: falls back to the static `parallel-batches` input on
missing/stale/absent data, identical contract to every other spine signal today).

## 3. Why this doesn't build it here

This is a new per-repo signal (merged-count query), a new persisted-state read (self
cross-run artifact fetch), a reviewed formula with constants that need real calibration
against live data (not just the four data points #357 happened to log), a new field
threaded through an existing artifact, and a consumption change in `requeue`'s dispatch
math that changes actual build throughput for every caller repo simultaneously — with no
staged rollout lever weaker than "ship it." `three-loop-pipeline.md` §8's declined-levers
table logs the standing lesson this doc's two siblings both cite: a session handed an
artifact-producing step it can't finish in-budget ships nothing, and anything downstream
that assumed the artifact now breaks too. This is also explicitly the kind of change
`issue-build.yml`'s own `effort-budget` shrink history (80→48→16→6, `issue-build.yml:73-76`)
and `parallel-batches` shrink history (4→2, `issue-build.yml:86-92`) show real operators
have tuned *conservatively and incrementally* before — a mechanized version should ship the
same way (behind a flag, compared against the static default, not defaulted live), not as
one 30-minute build.

## 4. Suggested follow-up issues (small enough to build individually)

- Add `merged_prs_in_window` (trailing 1-2h, per repo) to `fabric-health.yml`'s existing
  per-repo collector loop, under the same collection-integrity contract as the other
  collectors (§2.1) — small.
- Add the self cross-run artifact fetch (fabric-health reading its own previous run's
  `fabric-status.json` for prior `integral_error`/`checked_at`) mirroring #452's pattern
  (§2.2) — medium, depends on the signal above landing first (needs a field to persist).
- Write the reviewed PI-formula spec as its own doc (constants, window size, anti-windup
  bounds, calibration method against live #357-style data) — mirrors how the value-ranking
  score formula was specified (`2026-07-18-value-ranking-score-spec.md`) before any code —
  small, but should land before the next two items.
- Add `recommended_parallel_batches` to `fabric-status.json` and extend
  `issue-build.yml`'s existing spine-fetch step to read it, feeding `requeue`'s dispatch
  math with a budget-headroom dampener (§2.3/§2.4) — medium, behind a flag that compares
  against the static default before it becomes load-bearing.
- Live-calibrate `Kp`/`Ki`/window-size/`OUTPUT_CAP` against a real multi-day soak once the
  above lands, before removing the comparison flag.
