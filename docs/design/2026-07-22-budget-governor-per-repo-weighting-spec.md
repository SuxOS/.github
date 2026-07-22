# Budget-governor per-repo weighting formula — reviewed spec

> **Status:** design/spec only — no code in this doc.
> **Trigger:** #577, slice 1 of §4 in
> `docs/design/2026-07-20-budget-governor-per-repo-share-design.md` ("Write the
> reviewed per-repo weighting-formula spec ... should land before any of the below").
> Same "spec before code" discipline that doc's own §2 item 1 requires, mirroring
> `2026-07-19-drain-controller-pi-formula-spec.md` and
> `2026-07-18-value-ranking-score-spec.md`'s precedent of a reviewed formula doc
> landing before any consumer touches it.

## 1. Inputs

Per managed repo, both already computed elsewhere — no new collector needed, only new
composition (parent doc §2.1):

- `integral_error` — drain-controller's per-repo running PI-integral,
  `fabric-health.yml`'s per-repo collector loop, clamped to `[INTEGRAL_FLOOR,
  INTEGRAL_CAP] = [0, 20]` (`2026-07-19-drain-controller-pi-formula-spec.md` §2). `0`
  means "draining fine or ahead," `20` means "maximally behind, been behind a while."
  Only defined when that repo's own collectors were healthy this run
  (`collection.integral == 1 and collection.issues == 1`, per #575) — see §4 below for
  the degrade path when it isn't.
- `pressure_term` — value-ranking's own per-repo backlog-density term,
  `clamp(backlog_total / PRESSURE_CAP, 0, 1)` with `PRESSURE_CAP = 50`
  (`2026-07-18-value-ranking-score-spec.md` §2), already normalized to `[0, 1]`.
  Reused as-is rather than re-deriving a second backlog normalization, so this doc
  never drifts from what value-ranking already means by "backlog pressure."

Both inputs are per-repo scalars available in the same run (`fabric-status.json`),
already covered by the cross-workflow fetch this design's §2 item 2 scopes — this spec
only defines how to combine them once fetched.

## 2. Formula

Computed once per managed repo per `budget-governor.yml` sweep, over the full `$REPOS`
set:

```
INTEGRAL_NORM_CAP = 20    # matches drain-controller's own INTEGRAL_CAP exactly — reuse, not a new constant
drain_term_i    = integral_error_i / INTEGRAL_NORM_CAP        # already in [0, 1], no clamp needed (integral_error is pre-clamped at the source)
raw_weight_i    = 0.6 * drain_term_i + 0.4 * pressure_term_i

FLOOR_SHARE     = 0.05    # anti-starvation floor, see §3
n               = count(managed repos)

floor_pool      = FLOOR_SHARE * n              # total share reserved for floors, redistributed proportionally below
raw_sum         = sum(raw_weight_i for i in repos)
scaled_i        = if raw_sum > 0:
                     (raw_weight_i / raw_sum) * (1 - floor_pool)
                   else:
                     (1 - floor_pool) / n        # all repos equally quiet -> equal split of the non-floor pool
weight_i        = FLOOR_SHARE + scaled_i
```

`sum(weight_i for i in repos) == 1` by construction: every repo gets its
`FLOOR_SHARE`, and the remaining `(1 - floor_pool)` is split proportionally to
`raw_weight_i`. `repo_avail_i = pool_avail * weight_i` (parent doc §2 item 3) is where
this feeds `budget-governor.yml`'s existing `opus_avail_min`/`total_avail_min` split.

Weights (`0.6` drain / `0.4` pressure): drain-controller's `integral_error` is already
a *time-integrated* "how long has this repo been under-drained" signal — a repo can
have a thin backlog (`pressure_term` low) but still be genuinely stuck (merges have
stalled, `integral_error` climbing), and that stuck-ness is the more urgent case for
"more budget, now" than raw backlog size alone. `pressure_term` still matters (a big
backlog is real pending value even before the integral has climbed), so it keeps real
but secondary weight — same asymmetric-but-nonzero shape `2026-07-18-value-ranking-
score-spec.md` §2 already uses for its own three-term blend (0.45/0.25/0.30 there).

## 3. Anti-starvation floor

`FLOOR_SHARE = 0.05` (5% of the pool, unconditionally, before any proportional split)
directly answers the failure mode the parent doc §2 item 1 flags: a repo whose backlog
is thin *right now* (`pressure_term ≈ 0`) and whose drain integral is at its floor
(`integral_error = 0`, i.e. genuinely caught up) would otherwise compute `raw_weight_i
≈ 0` and get a real-zero share — starving it the instant it has anything new to build,
since a zero-budget repo can't even run one cheap issue to prove it needs more. `0.05`
is deliberately small (an idle, caught-up repo shouldn't out-earn a genuinely
struggling one) but nonzero by construction, mirroring value-ranking's own aging-term
precedent (`2026-07-18-value-ranking-score-spec.md` §3): both guard against a purely
multiplicative score driving a legitimate case all the way to zero and getting stuck
there, just on different axes (backlog age there, per-repo share here).

`floor_pool = FLOOR_SHARE * n` grows with fleet size — at today's 4 managed repos
(`sux`, `suxrouter`, `claude-config`, `suxlib`) that reserves `20%` of the pool for
floors and splits the remaining `80%` proportionally; this scales automatically as
repos join per the org repo list in this repo's own README, no separate per-repo-count
constant to keep in sync.

## 4. Degrade path when a repo's inputs aren't fresh

Per the collection-integrity contract this pipeline already applies everywhere else
(`CLAUDE.md`, `fabric-health.yml`'s `collection.*` gates, #575's fix to
`integral_error` specifically): a repo whose `fabric-status.json` fetch is missing,
stale, or whose `collection.integral`/`collection.issues` read `0` this run must NOT
compute a fabricated `raw_weight_i` from a zero/default input. Instead, that repo's
`raw_weight_i` is treated as **unknown** and excluded from `raw_sum` and the
proportional split entirely — it still receives its unconditional `FLOOR_SHARE`
(§3), same as every other repo, but no proportional top-up until its signal is
observed fresh again. This is the same "excluded from the sum, never counted as zero"
shape `2026-07-19-inflow-bound-comparison-spec.md` §2 already uses for a repo missing
from `drain_rate_per_day` — deliberately reused here rather than inventing a third
variant of the same contract.

## 5. Out of scope

This spec defines the weighting formula only. The cross-workflow fetch of each repo's
`integral_error`/`pressure_term` into `budget-governor.yml`, the shadow-mode-only
compute, the write-path change to "Set per-repo throttle issues", and the live
multi-day calibration soak are the parent doc's §2 items 2/3/4 and §4's remaining
follow-up issues — not re-derived here. In particular, the exact constants above
(`0.6`/`0.4` blend weights, `FLOOR_SHARE = 0.05`) are this spec's own reasoned
starting point, not yet calibrated against a live multi-repo soak — the parent doc's
final §4 follow-up (live-calibrate before removing the comparison flag) is where these
get adjusted against real data, the same "seeded, not yet soak-calibrated" caveat
`2026-07-19-drain-controller-pi-formula-spec.md` §5 already flags for its own
constants.
