# Inflow-bound (backlog-refills-faster-than-drain) comparison — reviewed spec

> **Status:** design/spec only — no code in this doc.
> **Trigger:** #555, the follow-up named in
> `docs/design/2026-07-19-next-arc-decision-rule-design.md` §3.3 ("spec the inflow-bound
> formula before coding it ... should land before [the reconciler] consumes it"). Same
> "commit the plan so it survives issue closure" discipline as that doc's siblings, and
> mirrors `2026-07-19-drain-controller-pi-formula-spec.md`'s own formula-spec-before-code
> precedent (#472) — unlike that spec, which had #357's own worked arithmetic to check
> against, there is no existing hand-derivation of this comparison to reverse-engineer, so
> the derivation below is this doc's own.

## 1. Inputs

Both already collected by `fabric-health.yml`, no new collector needed — only new
composition:

- **Backlog growth rate**, `backlog_growth_per_day` — org-wide, already computed by the
  #554 multi-day history read (`fabric-health.yml`'s "Multi-day backlog history" step) as
  `(backlog_total[newest] - backlog_total[oldest]) / span_days` across the sampled
  calendar. `null` when fewer than 2 sampled days are available
  (`history.days_available < 2`) — the history step's own `growth_rate` jq function
  already returns `null` in that case, not a fabricated 0.
- **Drain rate proxy**, `merged_prs_in_window` — per-repo, trailing-window PR merge count
  (`fabric-health.yml`'s existing drain-controller collector, #473), gated by
  `collection.merged` (a failed query is `0` **and** `collection.merged=0`, never a
  healthy-looking zero, per the collection-integrity contract). `WINDOW_HOURS` is this
  same collector's own window (`merged-window-hours` input, default `2`), not a new
  constant.

There is no org-wide historical merge count (only per-repo point samples each run, not
carried across days the way `backlog_total` is), so the drain side of this comparison
cannot reuse the exact same multi-day sampling the growth side uses. Extrapolating the
existing 2h window sample to a daily rate is the only drain signal actually available
without adding a new collector — see §2's `INFLOW_WINDOW_DAYS` note for why this is an
acceptable (if noisier) proxy rather than a blocker.

## 2. Formula

Computed once org-wide per reconciler run (org-wide because the §4 table's rows are a
fleet-level arc decision, not a per-repo one — though the same formula composes
per-repo if a future consumer needs that granularity, using each repo's own
`history.repos[<repo>].backlog_growth_per_day` and `merged_prs_in_window`):

```
drain_rate_per_day   = sum(repo.merged_prs_in_window for repo in repos if repo.collection.merged == 1)
                        * (24 / WINDOW_HOURS)
inflow_bound          = (backlog_growth_per_day != null)
                        and (backlog_growth_per_day > MIN_SIGNAL_PER_DAY)
                        and (backlog_growth_per_day > drain_rate_per_day)
```

Constants (this spec's own additions):

- `MIN_SIGNAL_PER_DAY = 1` — a repo's issue count is integer-grained, so treat anything
  below one net new issue per day as noise, not real inflow pressure. This is also the
  tie-break for "both near zero" (§3): if `backlog_growth_per_day` doesn't clear this
  floor, the row doesn't match regardless of how low `drain_rate_per_day` is.
- `WINDOW_HOURS` — reuses the drain-controller's own `merged-window-hours` input
  (default `2`), not a separate constant, so this comparison never silently drifts from
  what the drain-controller signal actually measures.

Any repo missing from the sum (its `collection.merged` was `0` this run — a failed
query, not a real zero) is excluded from `drain_rate_per_day` rather than counted as
zero drain, same collection-integrity contract as every other collector here. A repo
excluded this way undercounts `drain_rate_per_day` (never overcounts), which only ever
makes `inflow_bound` easier to trigger, never harder — the safer direction for a signal
that gates an arc-changing decision, since a false "keep draining" read is worse than an
extra "consider self-direction" flag that a human then reviews.

## 3. Tie-break when both signals are near zero

A backlog that is genuinely flat (near-zero growth, near-zero drain — e.g. a quiet repo
with almost no new issues and almost no merges) must **not** read as inflow-bound just
because `drain_rate_per_day` happens to round to a hair below `backlog_growth_per_day`.
The `MIN_SIGNAL_PER_DAY` floor on `backlog_growth_per_day` (§2) is the tie-break: growth
has to clear a real floor before the comparison even runs, so two near-zero numbers
never trigger the row on a coin-flip of rounding. There is deliberately no symmetric
floor on `drain_rate_per_day` — a repo with real growth (clears the floor) and literally
zero merges in the window is exactly the inflow-bound case the row exists to catch, not
an edge case to suppress.

## 4. Data-availability gate

`inflow_bound` requires `backlog_growth_per_day != null`, i.e. `history.days_available
>= 2`. On a fresh rollout (fewer than 2 sampled days yet) or after a multi-day gap in
the history read, the comparison is simply not evaluable — the reconciler (#556) must
treat this as "row doesn't match" (fall through to the table's next row), the same
fail-soft-to-not-matched contract `null` gets everywhere else in this design, never as
a fabricated match or a fabricated non-match dressed up as a real read.

## 5. Out of scope

This spec defines the comparison only. Where in the §4 table's evaluation order this
row sits relative to the others, how its result feeds the tracking-issue body, and the
reconciler's own cadence are #556 (parent design doc §3.4) and #557 (§3.5) — not
re-derived here.
