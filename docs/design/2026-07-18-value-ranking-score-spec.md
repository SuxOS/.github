# Value-ranking score formula — reviewed spec

> **Status:** design/spec only — no code in this doc.
> **Trigger:** #451, the blocking prerequisite named in
> `docs/design/2026-07-18-value-ranking-selection-design.md` §2.2/§5 item 2 (a reviewed
> score-formula spec unblocks the other three slices: signal fetch [#452], the sort
> implementation, and the live-verify check). Same "commit the plan so it survives
> issue closure" discipline as that doc and its epic-decomposition sibling.

## 1. Inputs

Per issue, already computed in `select` (`issue-build.yml:371-413`), no new signal needed:

- `tier` — `high` (`priority:high`/`security`), `med` (`priority:med`), `low` (floor).
- `points` — `pointsFor(labels)`: small=1, medium=2 (default), large=4.
- `age_days` — `(now - issue.created_at) / 86400`.

Per repo, fetched cross-workflow from `fabric-status.json` (#452's own scope — the
fetch step lands the raw numbers as job outputs; nothing before this spec exists to
consume them, which is why #452 depends on this doc landing first):

- `backlog_pressure` — `suxos_backlog_total` for the issue's own repo, as fetched.
- `headroom` — budget-governor's `opus_avail_min / total_avail_min` (`budget-governor.yml:160-198`),
  a value in `[0, 1]`. Not yet plumbed into `select` by any open issue — the sort slice
  (§2.4 of the parent doc) must add its own fetch for this the same way #452 does for
  the fabric-health artifact, following the same fail-soft contract below.

## 2. Formula

All sub-terms are normalized to `[0, 1]` before weighting so the weights below are
directly comparable:

```
tier_score    = {high: 1.0, med: 0.5, low: 0.0}[tier]
effort_fit    = 1 / points                              # small=1.0, medium=0.5, large=0.25
pressure_term = clamp(backlog_pressure / PRESSURE_CAP, 0, 1)   # PRESSURE_CAP = 50 (repo-open-issue count past which more pressure stops mattering)
headroom_term = 1 - headroom                             # low headroom -> lean toward cheap/thin work, so this is a THIN-effort tiebreaker only (§4), never a reason to skip an issue

base_score = 0.45*tier_score + 0.25*effort_fit + 0.30*pressure_term
```

`headroom_term` is deliberately excluded from `base_score` — see §4 for why it's a
depth/thinness signal, not a selection-order signal.

Weights (0.45 / 0.25 / 0.30) reflect: tier is still the primary human-set signal
(highest weight, matching today's HIGH-first behavior); backlog pressure is the
actual "self-direction" input the vX-arc row asks for (#439), so it outweighs
effort-fit; effort-fit is real but secondary — a value-ranked queue that always
prefers the cheapest issue regardless of tier/pressure would just re-litigate the
existing effort-budget pack, not add value-ranking.

## 3. Aging term (anti-starvation, §2.3 of the parent doc)

A pure `base_score` sort risks the mirror of the bug already fixed once in the tier
pack (`issue-build.yml:381-391`, thin-HIGH-tier starving MED/LOW): a persistently
low-`base_score` old issue (e.g. `low` tier, `effort:large`, in a low-pressure repo)
never rises to the top and rots forever, since nothing in `base_score` moves as the
issue ages.

Fix: blend toward the maximum possible score as age approaches a cap, so an old
enough issue eventually outranks everything regardless of its own tier/effort/pressure:

```
AGE_CAP_DAYS = 21   # matches the reap-stale-claim discipline's order of magnitude (hours, not days) scaled up by ~250x for "backlog rot", not claim staleness — deliberately generous so this only fires on genuinely neglected issues, not normal queue depth
age_factor = clamp(age_days / AGE_CAP_DAYS, 0, 1)

final_score = base_score * (1 - age_factor) + 1.0 * age_factor
```

At `age_days >= AGE_CAP_DAYS`, `final_score == 1.0` — the issue sorts as if it were
`high`/cheapest/max-pressure, guaranteeing pick on the next run regardless of budget
pack order (still subject to the existing points-budget pack loop, so "guaranteed top
of sort" is not "guaranteed built this run" if the budget is already exhausted by
other age-capped issues — see §5).

## 4. Why headroom is a depth signal, not a selection-order signal

Folding `headroom_term` into `base_score` would mean "budget is tight this week" makes
an issue *less likely to be picked at all* — which contradicts three-loop-pipeline.md's
standing rule that builds always drain at yellow and only stand down at red
(`check-throttle`'s `defer-at: red`, already gating `select` upstream). Low headroom
should make the picked batch *thinner* (fewer turns, cheaper model), not different in
*which* issues get picked. So `headroom` stays out of the sort key entirely; it only
ever feeds `sensedOpus`/turns-scaling, which `select` already computes independently
(`issue-build.yml:404-` on). This spec does not change that wiring.

## 5. Replacing the pack (§2.4 of the parent doc, not built here)

The existing greedy budget-pack loop (`issue-build.yml:392-404`) keeps its shape —
tier-then-spillover, greedy against `effortBudget`/`maxIssues` — except the per-tier
`sort((a,b) => a.number - b.number)` (line 391) becomes
`sort((a,b) => finalScore(b) - finalScore(a))` computed with this spec's formula, and
the three-tier `for` loop (`high, med, low`, line 388) collapses to one pass over all
`selectable` issues sorted by `final_score` descending, since tier is now an input to
the score rather than an outer grouping. `pointsFor`/`effortBudget`/`maxIssues`
otherwise behave identically — same greedy accept-while-under-budget loop, just a
different sort key feeding it.

## 6. Fail-soft contract (binds §2.1/#452 and any future headroom fetch)

Any signal this formula depends on that comes from a cross-workflow fetch (backlog
pressure today, headroom whenever its own fetch lands) must degrade to a neutral
default — `pressure_term = 0`, `headroom_term` unused per §4 — on missing/stale data,
never fail the build or block selection. This mirrors #452's own fail-soft
requirement; a formula that hard-requires fresh spine data would turn an unrelated
fabric-health outage into an issue-build outage across every caller repo, which is
exactly the caller-facing blast-radius problem this repo's own CLAUDE.md warns about.
