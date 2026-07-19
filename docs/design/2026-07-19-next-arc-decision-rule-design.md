# Mechanizing the vX §4 next-arc decision rule — scoping pass

> **Status:** design/scoping only — no code in this doc.
> **Trigger:** #477, re-deriving the plan after #322 ("Mechanize the §4 next-arc reading")
> and #383 ("Mechanize the vX next-arc §4 phase-2 decision rule") were both closed
> 2026-07-18 with **no implementing commit** —
> `docs/design/2026-07-18-epic-decomposition-design.md` §4 caught and named this exact
> pattern for the adjacent epic-decomposition ask and rescued it with a scoping doc; this
> is the same rescue applied to the §4 mechanization, which hadn't received it yet. Same
> "commit the plan so it survives issue closure" discipline as that doc and
> `2026-07-18-value-ranking-selection-design.md`.

## 1. Problem

`docs/design/2026-07-16-suxos-vx-next-arc.md` §4 defines a decision table — gate first (7
consecutive days of unattended zero backlog, spine green, fixer inflow on for the last 3),
then take the first row that matches: drain-green+headroom → scale-unit-of-work,
drain-green+low-headroom → budget/cadence tuning, backlog-refills-faster-than-drain →
self-direction, edge-panels-red → edge-reliability, baseline-never-stabilizes →
more-stability. Today that reading happens by hand in the live #357 tracking issue (132
comments as of this pass) every cadence check-in. Nothing posts or updates which row
currently matches.

## 2. Re-deriving against the CURRENT code (not the #433/#439-era snapshot)

Each row's precondition maps onto a signal that is either already live, partially live, or
genuinely missing:

- **Drain-green + headroom rows.** `budget-governor.yml` already computes
  `opus_avail_min`/`OPUS_BUDGET_MIN` as an org-wide headroom fraction
  (`budget-governor.yml:198-200`) and writes it into every managed repo's "Autonomy
  throttle" issue body as prose (`budget-governor.yml:407`). Usable today, no new
  plumbing — just needs a place to read the number from (see §3).
- **"Drain green ... stays there 7 consecutive days"** — this is the part that turns out
  NOT to be mechanically readable today. `fabric-health.yml` deliberately does *not* track
  the streak itself ("stateless by design ... derived in Prometheus from series history,
  NOT tracked in the workflow", `fabric-health.yml:14-17`); the actual computation is a
  Grafana-only PromQL expr, `min_over_time(suxos_backlog_zero[7d])`
  (`grafana/fabric-health-dashboard.json:196`). This repo has **no Grafana query-back
  capability anywhere** — every `GRAFANA_*` secret and every use of them
  (`fabric-health.yml`, `self-check.yml`) is one-way *push* (Prometheus remote-write +
  Loki). A reconciler that needs "has backlog been zero for 7 straight days" cannot read
  that off Grafana without standing up the first query integration this org has ever had.
  The cheaper alternative — reusing #475's self cross-run artifact-fetch pattern
  (`fabric-health.yml:101-145`), but pointed at up to 7 days of prior runs instead of just
  the last one — is real new work (that pattern today only ever fetches ONE prior run),
  not a read of something that already exists.
- **"Backlog refills faster than drain" (inflow-bound).** No existing signal compares
  backlog *growth* rate to drain rate — `merged_prs_in_window` (#473) gives a drain-rate
  proxy, and `backlog_total` gives point-in-time size, but nothing today diffs successive
  `backlog_total` samples to get a growth rate. This needs its own small formula, the same
  way `recommended_parallel_batches`'s PI formula got its own spec doc
  (`2026-07-19-drain-controller-pi-formula-spec.md`) before any code, rather than being
  invented ad hoc inside a reconciler.
- **"Edge panels burn error budget" (suxos.net probes red).** `fabric-health.yml`'s
  `edge-smoke-checks` input already runs the probes and emits
  `suxos_edge_deploy_ok{service}` — but only into the Grafana push
  (`edge-metrics.txt` → `prom-body.txt`, `fabric-health.yml:421-441`). The result is
  **never folded into `fabric-status.json`** — the artifact this design's reconciler would
  actually read has no edge-check field at all today. Same Grafana-query gap as the 7-day
  streak: dead end without either a new query integration or persisting the check result
  into the artifact directly (the latter is small and reuses infra already running in the
  same job).
- **"Baseline never stabilizes"** is the table's own fallback (no other row matched over a
  full gate cycle) — mechanically it falls out of the same 7-day history read the streak
  row needs, not a separate signal.

So of five table rows, two (`headroom`) are cheap today, and three (`7-day streak`,
`inflow-bound`, `edge-panels`) each need genuinely new work — a history read that doesn't
exist yet, a formula that doesn't exist yet, and a persisted field that doesn't exist yet,
respectively. This is a materially different (still nontrivial) shape than #476's
drain-controller PI-formula follow-up, which only needed to wire two already-computed
numbers together.

## 3. Concrete plan

1. **Persist the edge-check result into `fabric-status.json`.** Fold the per-service
   `suxos_edge_deploy_ok` verdicts computed in `fabric-health.yml`'s "Edge deploy smoke
   checks" step (currently written only to `edge-metrics.txt` for the Grafana push) into
   the JSON artifact as a top-level `edge_checks: [{service, ok}]` array, same
   collection-integrity shape as every other collector. Small, and a direct prerequisite
   for row 4 to ever be readable outside Grafana.
2. **A bounded multi-day cross-run history read.** Extend the #475 self cross-run fetch
   pattern (`fabric-health.yml:101-145`) from "fetch the one prior run" to "fetch the last
   N successful daily runs" (sampling once per day, not every 15-minute run, keeps this to
   ~7 `gh run`/`gh run download` calls instead of ~672) and derive, per repo and org-wide:
   the backlog-zero streak length in days, and a naive backlog growth rate
   (`Δbacklog_total / Δdays` across the sampled points) for the inflow-bound comparison.
   Medium — depends on nothing else in this list, but is the largest single piece here.
3. **Spec the inflow-bound formula before coding it.** A short doc (mirrors
   `2026-07-19-drain-controller-pi-formula-spec.md`'s formula-before-code precedent):
   what counts as "backlog refills faster than drain" precisely (e.g. growth rate from #2
   vs. `merged_prs_in_window`-derived drain rate, over what window, what tie-break when
   both are near zero). Small, should land before step 4 consumes it.
4. **The reconciler itself.** A step (in `fabric-health.yml`, which already sweeps
   cross-repo state on a schedule, or a small new low-frequency workflow — day-granularity
   inputs don't need a 15-minute cadence) that takes the streak/headroom/inflow/edge
   signals from #1-3 and this repo's existing headroom fraction, evaluates the §4 table's
   first-match row, and upserts one tracking issue (`upsert-tracking-issue`, same
   dedup-by-title pattern as `budget-governor.yml`'s org-wide report) stating which row
   currently matches and the evidence for each precondition it checked. Medium, depends on
   #1-3 landing first — this is the piece that actually replaces the hand-derivation in
   #357.
5. **Cadence.** Wire the reconciler on a daily (or similarly coarse) schedule distinct
   from `fabric-health.yml`'s 15-minute cron — the gate is inherently day-granularity, and
   running it every 15 minutes would just mean 96 identical reads a day. Small, config-only
   once #4 lands.

## 4. Why this doesn't build it here

Three of the five table rows need real new work — a multi-day history read that doesn't
exist at any granularity today (the closest precedent, #475, only ever carries one prior
run), a comparison formula with no derivation to reverse-engineer (unlike the PI controller,
which had #357's own worked arithmetic to check against), and a signal that's computed but
never persisted anywhere a reconciler could read it back from. Attempting all of #3.1-3.4 in
one pass risks the exact failure this doc's own trigger describes: #322 and #383 already
tried to swallow this whole and both closed with nothing shipped. `docs/design/
three-loop-pipeline.md` §8's declined-levers table names the standing lesson directly:
a session handed an artifact-producing step it can't finish in-budget ships nothing, and
anything downstream that assumed the artifact now breaks too. The gate this table exists to
serve (§4's own "7 consecutive days ... fixer inflow re-enabled for at least the last 3")
also isn't met yet per the live #357 log (`Phase: draining`), so there is no live urgency
forcing all of this into one session — the small slices in §3 land independently and are
each individually useful (e.g. the edge-check persistence in step 1 is a real gap
regardless of this doc, and the headroom number is already usable with zero new code).

## 5. Suggested follow-up issues (small enough to build individually)

- Persist per-service edge-check verdicts into `fabric-status.json` (§3.1) — small,
  independent of everything else here.
- Extend fabric-health's self cross-run fetch to a bounded multi-day (daily-sampled)
  history read, deriving the backlog-zero streak length and a naive backlog growth rate
  (§3.2) — medium, the largest single piece; independent of #3.1.
- Spec the inflow-bound (backlog-refills-faster-than-drain) comparison formula as its own
  doc before any code (§3.3) — small, should land before the reconciler consumes it.
- Build the §4 reconciler: evaluate the first-match row from the streak/headroom/inflow/
  edge signals and upsert one tracking issue with the current verdict and evidence (§3.4)
  — medium, depends on the three above landing first.
- Wire the reconciler on a daily (not 15-minute) cadence, separate from
  `fabric-health.yml`'s existing cron (§3.5) — small, config-only once the reconciler
  exists.
