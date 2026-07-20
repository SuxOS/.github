# Budget-governor per-repo value-weighted share — scoping pass

> **Status:** design/scoping only — no code in this doc.
> **Trigger:** #542. Same shape of ask as #433 (multi-repo epic decomposition) and #439
> (value-ranking issue selection), scoped the same way in
> `docs/design/2026-07-18-epic-decomposition-design.md` and
> `docs/design/2026-07-18-value-ranking-selection-design.md`: re-derive a concrete plan,
> size it into independently-buildable slices, and commit the plan so it survives issue
> closure instead of being lost like those docs' own precedents (#419/#383/#433's first
> attempt — see the epic doc's §4 for the failure mode this guards against).

## 1. Problem

Three mechanisms in this pipeline have each independently built one piece of a
capability nobody has assembled yet:

1. `budget-governor.yml`'s "Sweep runs and compute utilization" step (id `sweep`, lines
   135-242) computes a single **org-wide** token-bucket simulation over every repo in
   `$REPOS` combined, yielding one `level`/`opus_avail_min`/`total_avail_min` triple.
   "Set per-repo throttle issues" (lines 402-467) then writes that *identical* body into
   every managed repo's own "Autonomy throttle" tracking issue in a loop — every repo
   sees the same global headroom regardless of its own demand.
2. The drain-controller (`docs/design/2026-07-19-drain-controller-pi-formula-spec.md`,
   implemented in `fabric-health.yml`'s per-repo collector loop and consumed in
   `issue-build.yml`'s `requeue` job, ~line 1149-1170) computes `recommended_parallel_batches`
   **per repo** from that repo's own backlog/merge-rate specifically because "a busy
   repo's real drain need must not get diluted into an aggregate" (parent doc
   `2026-07-18-drain-controller-design.md` §2.1) — but the headroom term it dampens with
   (`issue-build.yml:1167`, `THROTTLE_LEVEL`) is read off the same flat per-repo throttle
   issue from (1), so every repo's dampening fraction is identical too (`0.5` if any repo
   is yellow, `1` if green — never repo-specific).
3. The value-ranking score formula (`docs/design/2026-07-18-value-ranking-score-spec.md`
   §2) ranks issues only **within** one repo's own backlog, using that same
   undifferentiated global `headroom` scalar as a thin-effort tiebreaker (§4), and never
   compares one repo's value density against another's.

The result: when two repos are simultaneously inflow-bound, the pipeline has no
mechanism to prefer the one with a bigger or higher-value backlog — both get throttled
identically by the same flat number, even though `docs/design/budget-and-cadence.md`
describes the Claude Max subscription's weekly bucket as a single genuinely shared
resource that automation draws from across every repo at once. Now that both the
per-repo drain signal (drain-controller, item 2) and the per-issue value score
(value-ranking, item 3) exist and are live, the natural next capability is generalizing
from "which issue in this repo" to "which repo gets a bigger share of the shared pool
right now" — budget-governor computing a per-repo *proportional share* of the pool
weighted by each repo's drain-controller error/value-density, instead of broadcasting one
flat number.

## 2. Concrete plan

Every primitive this needs already exists; the risk is in composing them across two
workflows that don't currently talk to each other, not in inventing new signals:

1. **Weighting-formula spec.** Write a reviewed spec (weights, normalization, and — the
   part with no existing precedent to copy — a floor/aging term) for how each repo's
   drain-controller `integral_error` (or its own backlog/merge-rate inputs, pre-clamp) and
   value-ranking's per-repo `pressure_term`/`base_score` density combine into one
   normalized per-repo weight in `[0, 1]`, `sum(weights) == 1` across managed repos. This
   mirrors `2026-07-19-drain-controller-pi-formula-spec.md` and
   `2026-07-18-value-ranking-score-spec.md`'s own formula-spec-before-code precedent —
   no code should land before this exists, same discipline both of those docs enforced
   on themselves. Needs an explicit anti-starvation floor (a repo with a thin backlog
   right now still gets a nonzero minimum share) or this reintroduces the exact starvation
   bug the value-ranking doc's own §2.3 flagged and had to design around for issue
   ordering — the fleet-wide version would be worse, since a repo pinned at zero share
   stops draining entirely rather than just sorting last.
2. **Cross-workflow fetch.** `budget-governor.yml`'s sweep step needs each managed repo's
   current `integral_error`/`backlog_total` from `fabric-health.yml`'s latest
   `fabric-status.json` artifact — a different workflow, different run, so this is a
   cross-workflow `actions/download-artifact` call by `repository`+`run-id` (the same
   shape `2026-07-18-value-ranking-selection-design.md` §2.1 already scoped for
   `issue-build.yml`'s own artifact fetch, not yet built there either). Missing/stale
   artifact must degrade to today's flat-split behavior for that repo, not fail the
   entire governor run — `budget-governor.yml`'s existing fail-closed-on-truncation
   posture (lines 152-160) is for its *own* `gh run list` collection, a different
   contract than this new fetch's fail-*soft* one, and the two must not be conflated.
3. **Allocation.** Convert the existing single `opus_avail_min`/`total_avail_min` scalars
   into a normalized split: `repo_avail = pool_avail * weight_i` (from step 1's spec),
   computed alongside — not replacing — the existing flat org-wide numbers, so the "how
   much ran this week" diagnostic in the report issue (`budget-governor.yml`'s org-wide
   report, upserted via `upsert-tracking-issue` ~line 393) keeps reporting the true
   aggregate.
4. **Write path.** "Set per-repo throttle issues" (lines 402-467) writes each repo's
   `repo_avail` into that repo's own body instead of the flat `OPUS_AVAIL_MIN`/
   `TOTAL_AVAIL_MIN` env values it uses today — a small change in that loop once steps 1-3
   exist, but the loop's existing per-repo `throttle-manual` pin-skip (line 451) and
   fail-soft-per-repo `continue` guards (lines 445, 456, 462) must keep working
   unmodified, since those already handle the "one repo's write fails, others must not go
   stale" case this change doesn't touch.
5. **Consumption.** `issue-build.yml`'s `check-throttle` action and the drain-controller
   headroom-dampening read (`issue-build.yml:1167`) already read *a* per-repo throttle
   issue body — no structural change needed there, only the numbers embedded in that body
   change from "the fleet's flat share" to "this repo's actual share." Same for
   value-ranking's `headroom_term` once #439's slices land — it already reads per-repo,
   it just receives a differentiated number for free once this ships.
6. **Rollout gate.** Ship computed shares in shadow mode first (log alongside the
   existing flat write, change nothing written) for at least one multi-day soak spanning
   two simultaneously-busy repos, the same calibration discipline
   `2026-07-19-drain-controller-pi-formula-spec.md` §5 already specified for its own
   formula — only flip to writing the per-repo number once that soak shows no repo
   pinned near-zero share for an extended stretch while genuinely inflow-bound.

## 3. Why this PR doesn't build it

This is large and cross-cutting in a way distinct from — and riskier than — its two
scoped siblings: `budget-governor.yml` is not a downstream consumer like drain-controller
or value-ranking, it is the fleet-wide backstop every managed repo's `check-throttle`
gate defers to (`defer-at: red` stops issue-build from running *at all*). A bug in a
per-repo split here doesn't just misorder one repo's backlog — it can silently
under-throttle a repo past real budget or over-throttle a busy one to near-zero share
across the *entire* fleet simultaneously, with no staged rollout lever weaker than "ship
it" once the write path (§2 item 4) is live. `docs/design/three-loop-pipeline.md` §8's
declined-levers table logs the standing lesson every sibling scoping doc in this repo
cites for exactly this shape of change: a session handed an artifact-producing step it
can't finish in its turn budget ships nothing, and a downstream step that depended on
that artifact (here, every repo's throttle gate) is now broken too — the "clustering"
anti-pattern this pipeline has already been burned by once. Attempting the weighting
spec, the cross-workflow fetch, the allocation math, and the write-path change together
in one 30-minute build session risks that failure mode at the highest blast radius of
any change these precedent docs have scoped so far. The right shape is the six numbered
slices in §2, each independently buildable, with the weighting spec (item 1) and the
shadow-mode-only compute (item 6) landing well before the write path (item 4) ever
changes what a real repo's throttle issue says.

## 4. Suggested follow-up issues (small enough to build individually)

- Write the reviewed per-repo weighting-formula spec — how drain-controller
  `integral_error` and value-ranking's per-repo value-density combine into a normalized
  `weight_i` with an anti-starvation floor (§2.1) — small, should land before any of the
  below.
- Add the cross-workflow fetch of `fabric-health.yml`'s latest `fabric-status.json` into
  `budget-governor.yml`'s sweep step, fail-soft per repo to today's flat split on
  missing/stale data (§2.2) — medium, depends on the spec above only for the shape of
  what to extract, can otherwise be built independently.
- Compute the per-repo share in shadow mode only — log `repo_avail` per repo alongside
  the existing flat `opus_avail_min`/`total_avail_min` write, change nothing written
  (§2.3/§2.6) — small, depends on the two items above.
- Change "Set per-repo throttle issues" to write the per-repo share instead of the flat
  number, behind a flag defaulting off until the shadow-mode soak (previous item) shows
  no repo starved to near-zero share for an extended stretch (§2.4) — medium, depends on
  the shadow-mode item.
- Live-calibrate the weighting formula against a real multi-day soak across at least two
  simultaneously-busy repos before removing the comparison flag — mirrors
  `2026-07-19-drain-controller-pi-formula-spec.md` §5's own calibration follow-up.
