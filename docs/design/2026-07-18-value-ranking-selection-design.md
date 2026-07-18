# Value-ranking issue selection — scoping pass

> **Status:** design/scoping only — no code in this doc.
> **Trigger:** #439, the vX-arc's own "Self-direction" row —
> `docs/design/2026-07-16-suxos-vx-next-arc.md:90`: "the pipeline prioritizes *what* to
> build (value-ranking over FIFO tiers), guided by spine signals" — the candidate next
> arc when the spine baseline is inflow-bound (backlog refills faster than it drains).
> Same shape of ask as #433 (multi-repo epic decomposition), scoped the same way in
> `docs/design/2026-07-18-epic-decomposition-design.md`: re-derive a concrete plan,
> size it into independently-buildable slices, and commit the plan so it survives
> issue closure instead of being lost like #419/#383/#433's first attempt (see that
> doc's §4 for the failure mode this guards against).

## 1. Problem

`select` in `.github/workflows/issue-build.yml` (~line 371-413) is exactly the
FIFO-within-tier system the vX-arc table contrasts against "self-direction" with:
issues are bucketed into `high` (`priority:high` or `security`), `med`
(`priority:med`), `low` (everything else) — line 377-379 — then each tier is packed
oldest-issue-number-first against a points budget (`pointsFor`, line 375: small=1,
medium=2/default, large=4) until `maxIssues` or `effortBudget` is hit, spilling into
the next tier once the current one is exhausted (line 381-404). No signal beyond
label-tier + issue-number-age + a coarse effort guess ever enters selection.

The primitives a value score would need already exist and are already flowing in
production, per #439's own body:

- **Effort estimates** already flow from the builder's own `observations.json`
  capture (`issue-build.yml` step 5, "effort" field) into the `effort:*` labels
  `pointsFor` reads (line 375) — this is the effort-fit signal.
- **Spine backlog-pressure** is already collected: `fabric-health.yml` writes
  `suxos_backlog_total`/`suxos_workflow_red_total`/`suxos_collection_ok` per repo into
  `fabric-status.json` (`fabric-health.yml:82-288`) and uploads it as a build artifact
  (`fabric-health.yml:406-410`) — "ground truth for the orient tool" per that step's own
  name. The Grafana Cloud push (`fabric-health.yml:312-`) is a *second*, separate sink
  and is dormant unless `GRAFANA_PROM_URL`/`GRAFANA_LOKI_TOKEN` etc. are set
  (`fabric-health.yml:10-11`) — the artifact, not Grafana, is the dependable read path
  for a same-org consumer.
- **Budget headroom** is already computed per tier: budget-governor's token-bucket
  simulation (`budget-governor.yml:160-198`) yields `opus_avail_min`/`total_avail_min`
  — "how much spend is left" before the next build should lean cheaper/thinner.

Nothing today combines these into a value score that replaces the plain oldest-first
pack within a tier.

## 2. Concrete plan

1. **Signal fetch.** `select` runs inside `issue-build.yml`, a `workflow_call` reused
   by every caller repo (`sux`, `suxrouter`, `claude-config`, `suxlib`, `.github`
   itself) — per this repo's own CLAUDE.md, a caller-facing default has no per-repo
   blast-radius limit, so the fetch must fail soft. `fabric-status.json` is produced by
   a *different* workflow (`fabric-health.yml`) in a *different* run, so pulling it
   into `select` means a cross-workflow `actions/download-artifact` call (by
   `repository`+`run-id` of fabric-health's latest run, with a `github-token` scoped to
   read it) — not a same-run artifact reference. Missing/stale artifact must degrade to
   today's tier-only behavior, not fail the build.
2. **Score.** A deterministic, auditable formula over already-known-per-issue inputs
   (tier, age, `pointsFor` effort) plus the fetched per-repo spine signals (backlog
   pressure, budget headroom) — explicitly *not* an opaque heuristic or a model call,
   per #439's own body ("a decision to make it deterministic/auditable"). Needs a
   reviewed spec (weights, and how backlog-pressure/headroom — both per-repo scalars —
   combine with per-issue tier/age/effort) before any code, the same way the epic
   doc's §2.1 schema was specified before #447 implemented it.
3. **Anti-starvation.** The current pack already had one starvation bug fixed live
   (`issue-build.yml:381-391`: a thin HIGH tier used to cap the whole batch at
   count=1 even with a full MED/LOW backlog waiting — fixed by spillover). A pure
   value-sort risks the mirror bug — a persistently low-scoring old issue never rises
   to the top and rots forever. Whatever score formula lands needs an aging term (score
   trends toward "always eventually pick" as an issue ages), not just a one-shot
   weighted sum, or it re-introduces the same class of bug in a new shape.
4. **Replace the pack, not the tiers.** Tiers (`priority:high`/`security` etc.) stay as
   real signal humans already set — the score should incorporate tier as one input
   rather than discard it, and the greedy budget-pack loop (line 392-404) keeps its
   shape, just sorted by score instead of `(tier, issue-number)`.

## 3. Why this PR doesn't build it

This is new cross-workflow signal plumbing (artifact fetch across workflow runs, with
a real failure mode to design for — stale/missing data — not just a happy path) plus a
scoring formula that changes *what gets built* for every caller repo simultaneously,
with no staged rollout lever weaker than "ship it." `three-loop-pipeline.md` §8's
declined-levers table already has the standing lesson this doc's sibling
(`2026-07-18-epic-decomposition-design.md` §3) cites: a session handed an
artifact-producing step it can't finish in-budget ships nothing, and anything
downstream that assumed the artifact now breaks too. #439 was already dropped once
from an earlier build session for exactly this reason (see the issue's own comment
thread) — a full implementation attempt in one 30-minute session is the same
under-scoped rush #446 was fixed to stop rewarding. The right shape is the four
numbered slices in §2, each independently buildable and each safe to land without the
others being done first (①③ are pure plumbing/logic changes gated behind a
feature-off default; ② is a spec, not code).

## 4. Live-data caveat

The vX-arc table's "self-direction" row triggers specifically on **inflow-bound**
(backlog refills faster than it drains) — a stricter condition than "backlog is
merely nonzero." #439 cites the #357 soak log showing backlog not-yet-zero across
every repo as suggestive, and the Autonomy budget report (#153, 2026-07-18: opus-tier
headroom ~48%, 429/900) shows spend is close to but not over the arc table's other
row's ≥50% threshold — but neither confirms *which* row's baseline condition the spine
is actually in right now. That needs a live read of `suxos_backlog_total` trend (is it
net-increasing or net-decreasing over the trailing window) at whatever point this is
picked up for implementation, not an assumption carried over from this doc's snapshot.

## 5. Suggested follow-up issues (small enough to build individually)

- Cross-workflow fetch of `fabric-status.json` into `issue-build.yml`'s `select` job
  (§2.1), with fail-soft degrade to today's tier-only pack on missing/stale data —
  medium.
- Write the deterministic value-score spec — weights over tier/age/effort-fit/backlog-
  pressure/headroom, plus the aging term from §2.3 — as a reviewed doc, not code yet
  (mirrors how the epic doc's schema shape was specified before implementation) —
  small.
- Implement the score-based sort replacing `(tier, issue-number)` ordering inside the
  existing budget-pack loop (§2.2/§2.4), behind a flag so it can be compared against
  the current pack before it becomes the default — medium, depends on the spec above.
- Live-verify whether the spine baseline is actually inflow-bound right now (§4)
  before treating this as the armed next arc rather than a scoped-but-parked option.
