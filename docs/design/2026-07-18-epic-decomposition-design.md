# Multi-repo "epic" decomposition — scoping pass

> **Status:** design/scoping only — no code in this doc. Committed so the plan survives
> issue closure this time (it didn't the last two times; see §4).
> **Trigger:** #433, re-deriving the plan #419 wrote and lost when #419 closed with no
> implementing commit. `docs/design/2026-07-16-suxos-vx-next-arc.md:90` §4 and
> `docs/design/2026-07-16-fabric-stability-v2-design.md` §Phase-2 both name this as the
> candidate next-arc row once drain is green and opus-bucket headroom sustains ≥50%.

## 1. Problem

Every issue-build.yml run is scoped to one repo's backlog. There's no unit of work that
spans repos — a change that needs a coordinated `sux` + `suxrouter` + `suxlib` PR today
has to be filed and tracked as three independent issues with no linkage, no shared
identity, and no single "is this done" signal. `three-loop-pipeline.md:631` already notes
cross-repo *parallelism* is free (M = number of repos, each with its own isolated
issue-build run); what's missing is cross-repo *coordination* — filing related child work
together and knowing when all of it has landed.

## 2. Concrete plan (re-derived from #419)

Every primitive this needs already exists; the mechanism is wiring, not new
infrastructure:

1. **Schema.** Add an optional `epic` field to the fixer/builder proposal schema (the
   `--json-schema` blocks in `fixer.yml:227,322`): `{"id": "string", "repos":
   ["repo-name", ...]}`. Omitted for ordinary proposals — this is additive, not a
   breaking change to the existing `proposals[]` shape.
2. **Filing.** When a proposal carries `epic`, a filing step opens one child issue per
   named repo (each repo's own issue-build.yml picks it up unmodified — no change to the
   per-repo build loop), tagging each `epic:<id>`, plus one tracking issue in `.github`
   via `upsert-tracking-issue` (`mode: open`, `update-mode: replace`, same dedup-by-title
   pattern `budget-governor.yml:367` already uses for the org-wide report) whose body is
   a checklist of the child issues.
3. **Reconciler.** A step folded into `fabric-health.yml` (which already sweeps
   cross-repo state on a schedule) lists open issues labeled `epic:<id>` across
   `managed-repos.json`'s repo list using `gh-list-exhaustive` (per this file's own
   CLAUDE.md guidance — no bespoke bounded list call), ticks the tracking issue's
   checklist as children close, and closes the tracking issue itself once all children
   are closed.
4. **Label.** `epic` is already reserved as a non-buildable-adjacent label
   (`fabric-health.yml:40`, `nonbuildable-labels/action.yml:10` — currently just excluded
   from backlog-zero counts). `epic:<id>` child/tracking labels are new but follow the
   same label-as-state-machine convention `three-loop-pipeline.md` already documents.
5. **Gate.** Per the vX decision rule (`2026-07-16-suxos-vx-next-arc.md` §4), this only
   arms once the 7-day unattended-drain-streak DoD is green *and* opus-bucket headroom
   sustains ≥50%. As of the Autonomy budget report (#153, 2026-07-18): opus-tier headroom
   ~48% (429/900) — close but not yet over the line, and the 7-day streak precondition
   needs live re-verification at arm time, not assumed from this snapshot.

## 3. Why this PR doesn't build it

This is new schema + cross-repo filing + a new scheduled reconciler loop + a live DoD
re-check — a genuinely large, multi-file, multi-repo change. `three-loop-pipeline.md`
§8's own declined-levers table has a standing lesson directly on point: a session that's
handed an artifact-producing step it can't finish in its turn budget ships nothing, and a
downstream step that depended on that artifact is now broken too (the "clustering
anti-pattern" that got the clustering pass retired). Attempting all four pieces above in
one 30-minute build session risks exactly that failure mode, at higher cost than usual
because the blast radius is cross-repo. The right shape is four small, independently
mergeable slices (§2's four numbered steps each stand alone), each its own issue, each
buildable in a normal single-repo session.

## 4. Meta-note: why this is attempt #3

#419 (design this) and #383 (mechanize the related next-arc row-selection) were both
closed 2026-07-18 with **no implementing commit** — confirmed by reading the closing PRs
(#422 and #388 respectively): both PRs' actual commits touch unrelated fabric-health/
detect-unreachable-checks work, not the epic mechanism or arc-selection logic the closed
issues describe. That looks like the exact disposition-handling failure this repo's own
issue-build.yml prompt warns about (a dropped issue left in, or defaulted into, the
`built` list gets auto-closed via `Closes #n` without ever having been built). This doc
exists specifically so the plan isn't lost a third time to the same failure — see the
filed follow-up bug observation from this build for the root-cause fix.

## 5. Suggested follow-up issues (small enough to build individually)

- Add the optional `epic` field to the fixer/issue-build proposal schema (§2.1) — small.
- Epic filing step: child issues + tracking issue via `upsert-tracking-issue` (§2.2) —
  medium, depends on the schema slice landing first.
- Epic reconciler pass in `fabric-health.yml` using `gh-list-exhaustive` (§2.3) — medium,
  independent of the filing slice (can be built and tested against hand-created
  `epic:<id>`-labeled issues before filing exists).
- Re-verify the 7-day drain-streak + ≥50% headroom DoD gate live, and gate arming the
  filing/reconciler slices on it, before any of the above ships enabled by default.
