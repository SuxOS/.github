# Drain-controller PI-formula — reviewed spec

> **Status:** design/spec only — no code in this doc.
> **Trigger:** #472, the follow-up named in
> `docs/design/2026-07-18-drain-controller-design.md` §4 ("write the reviewed PI-formula
> spec as its own doc … should land before the next two items"). Same "commit the plan so
> it survives issue closure" discipline as that doc's two siblings
> (`2026-07-18-epic-decomposition-design.md`, `2026-07-18-value-ranking-selection-design.md`)
> and mirrors `2026-07-18-value-ranking-score-spec.md`'s own formula-spec-before-code
> precedent (#451).

## 1. Inputs

Per repo, per fabric-health run (`fabric-health.yml`'s existing per-repo collector loop):

- `merged_prs_in_window` — count of PRs merged in the trailing window (§2, new signal,
  not yet collected anywhere — see parent doc §2.1). Under the same collection-integrity
  contract as every other collector here: a failed `gh pr list` query sets
  `collection_ok=0` for that repo, never reads as a healthy zero.
- `open_issue_count` — already collected (`suxos_backlog_total`, feeds `backlog_zero`
  today).
- `prior_integral_error`, `prior_checked_at` — read back from fabric-health's own
  previous run's `fabric-status.json` artifact (parent doc §2.2's self cross-run fetch;
  not yet built).

Constants (this spec's own additions, not derived from existing code):

- `TARGET_DRAIN_HOURS = 48` — matches the value the #357 soak log itself used for
  `setpoint`.
- `WINDOW_HOURS = 2` — trailing window for `merged_prs_in_window`. Parent doc §2.1 flags
  the #357 log's own pain point: a 14–23 min sample was too noisy for a human to trust
  without overriding it by hand, so the window must sit an order of magnitude past
  fabric-health's 15-min run cadence. Picking the wide end of the doc's "1-2h" candidate
  range rather than the narrow end: this controller runs unattended (no human catching a
  bad sample the way the #357 log's author did), so it should err toward the more
  noise-resistant option until live-calibrated otherwise (§5's follow-up item).
- `INTEGRAL_CAP = 20`, `INTEGRAL_FLOOR = 0` — anti-windup bounds, taken directly from the
  #357 log's own worked values (parent doc §2.1).
- `OUTPUT_CAP = 4` — ceiling on the controller's output, also taken directly from the
  #357 log.
- `Kp = 1`, `Ki = 0.2` — proportional/integral gains, taken directly from the #357 log
  and verified there against two real data points (parent doc §2.1).

## 2. Formula

Computed once per repo, per fabric-health run (parent doc §2.1: per-repo, not
fabric-wide — a busy repo's real drain need must not get diluted into an aggregate):

```
elapsed_hours   = (checked_at - prior_checked_at) / 3600          # wall-clock since last run
merged_rate     = merged_prs_in_window / WINDOW_HOURS
setpoint        = open_issue_count / TARGET_DRAIN_HOURS
error           = setpoint - merged_rate
integral_error  = clamp(prior_integral_error + error, INTEGRAL_FLOOR, INTEGRAL_CAP)
raw_output      = clamp(round(Kp * error + Ki * integral_error), 0, OUTPUT_CAP)
```

Verified against the #357 log's own worked arithmetic (parent doc §2.1):
`error=2.65, integral=4.92 -> round(1*2.65 + 0.2*4.92) = round(3.63) = 4` ✓;
`error=-1.0, integral=0 -> round(-1.0) clamped to 0` ✓.

`elapsed_hours` is computed but not otherwise used by the formula above — it exists so a
future implementation can detect a stale/skipped prior run (e.g. `elapsed_hours` far
outside the expected ~15-min cadence) and reset `integral_error` to `0` rather than
integrating across a gap the term was never calibrated for. This spec does not define
that reset threshold; treat it as a fail-soft edge the implementation must handle, not a
constant to bikeshed here.

## 3. Anti-windup

`integral_error` is clamped to `[INTEGRAL_FLOOR, INTEGRAL_CAP]` = `[0, 20]` on every
update, before it feeds `raw_output` — this is what keeps a long persistent deficit from
making the integral term grow unbounded and then overshoot once the backlog clears (classic
PI windup). The floor at `0` (rather than allowing negative accumulation) matches the
#357 log's own values and reflects that this controller only ever needs to push
*more* parallelism during a deficit, never accumulate credit for over-draining, since
`raw_output` itself is already floored at `0` by `OUTPUT_CAP`'s clamp.

## 4. Headroom dampening (parent doc §2.4, not re-derived here — composition only)

This spec defines `raw_output` only. The parent doc's §2.4 already specifies how
`budget-governor`'s headroom fraction dampens it before use:
`output = max(STATIC_DEFAULT, round(raw_output * headroom_fraction))` — dampen toward,
never below, the operator-configured static default. That composition is out of scope
here; this doc is the `raw_output` formula it composes with.

## 5. Calibration method against live data

The constants above (`Kp`, `Ki`, `INTEGRAL_CAP`, `WINDOW_HOURS`) are seeded from the
#357 log's four data points, not a multi-day soak — parent doc §3 already flags this as
the reason the change ships "behind a flag, compared against the static default" rather
than live. Calibration method for the follow-up that live-tunes them:

1. Run the formula in shadow mode (compute `raw_output` every fabric-health run, log it
   alongside the existing static `parallel-batches` value, do not feed it anywhere) for
   at least one full multi-day soak per active caller repo — long enough to span several
   `TARGET_DRAIN_HOURS` cycles, not just the #357 log's single afternoon.
2. Compare shadow `raw_output` against what a human would have picked at each interval
   (the same judgment call the #357 log's author made by hand) — flag intervals where
   they diverge by more than 1, the same tolerance implied by the log's own "deliberate
   override" cases (parent doc §2.4).
3. Only after that comparison shows the formula tracking the human judgment calls closely
   (no systematic over/under-shoot across a full cycle) does it become load-bearing —
   and even then, dampened by headroom (§4) and floored at the static default, never
   defaulted straight to authoritative.

This spec intentionally leaves `WINDOW_HOURS`, `INTEGRAL_CAP`, and the gains as
re-tunable constants rather than hard-coding them as load-bearing on day one; the
shadow-mode comparison in step 2 is what should decide whether they need adjustment
before the collector/consumption follow-ups (parent doc §4, items 1 and 4) go live.
