# SuxOS v2 — Fabric Stability Design

**Status:** Draft for review
**Date:** 2026-07-16
**Owner:** m@colinxs.com
**Phase:** 1 of 2 (Stability → Next Arc). Phase 2 gets its own brainstorming cycle after Phase 1 shows a stable baseline.

## Problem

SuxOS v2 spans the whole fabric: 6 repos, the `.github` three-loop cloud pipeline
(collate-build → green-merge → red-rebase) plus its budget governor, the `sux`
Cloudflare edge platform (+ `suxrouter`, `sux-fileops`), and the loci tooling
(`orient`/`work`/`dispatch`/`paste`). It works, but not *reliably* or *legibly*:
recurring incident classes keep recurring, fixes land as patches trapped in commit
messages rather than root-caused, and there is no single surface that shows whether
the fabric is healthy right now.

This spec converges the fabric to a state that is **reliable, legible, and observable** —
nothing more. It explicitly avoids new capabilities and premature optimization.

## Definition of Done

The fabric is "stable" when all of the following hold:

1. **Dashboard** — one Grafana surface shows live fabric health (see Spine).
2. **Pipeline drains unattended** — backlog → zero with no manual surgery for
   **7 consecutive days** (the drain-to-zero streak, measured by the spine).
3. **Edge services green** — `sux` / `suxrouter` / `sux-fileops` deploy cleanly and
   their runtime paths (proxy fallback, vault, fileops) work end-to-end.
4. **Fabric legible** — a new session can `orient`/`work`/`dispatch` across all repos
   from captured docs, with no tribal knowledge; invariants and failure-modes are
   written down, not inferred.
5. **No recurring fires** — each known incident class is root-caused (not patched),
   with the lesson folded into `CLAUDE.md`/docs and a spine signal that would catch a
   recurrence.

## Approach

Observability-first, then data-driven root-cause. Instrument the fabric so
stabilization is measured rather than felt, then fix the recurring fires against that
baseline. A freeze (disabling pipeline crons) is reserved only for a specific fix that
cannot be done live — the default is to keep the pipeline running, because convergence
is drain-throughput-bound and emergency-braking the pipeline fights the goal.

## Architecture — The Fabric Health Spine

One authoritative health surface, living in `.github` (the org-level locus),
Grafana-native by reusing the edge's existing telemetry pattern
(`sux/sux/src/grafana.ts`).

### Collector
A single scheduled workflow `fabric-health.yml` in `.github` unifies the existing
*health signals* — `health.yml` (per-service smoke checks) and `pipeline-utilization.yml`
(GitHub-API run rollups, which already maintains a tracking issue but pushes nothing to
Grafana) — into one cron pass. `self-check.yml` is out of scope: it is repo CI
(actionlint + regression guards), not a fabric-health signal, and stays as-is.
Across all 6 repos it reads:
- backlog depth (open issues eligible for build)
- PR states (open / red / stuck)
- each workflow's last conclusion
- the drain-to-zero streak (days since last manual surgery)
- budget-governor state
- edge-service deploy status (Cloudflare)

### Ship (reuse the edge pattern)
The collector builds an Influx line-protocol snapshot — mirroring `buildInfluxSnapshot`
in `sux/sux/src/grafana.ts` — and pushes to the **same Grafana Cloud Prometheus**
endpoint the edge already uses. Proposed metric namespace:
- `suxos_pipeline_backlog`
- `suxos_drain_streak_days`
- `suxos_workflow_red_total`
- `suxos_pr_stuck_total`
- `suxos_budget_state`
- `suxos_edge_deploy_ok`

Per-incident events are pushed to Grafana Cloud Loki under `{service="suxos-fabric"}`,
mirroring `shipToLoki`/`shipEgress`.

### Surface
A new **"SuxOS — fabric health"** dashboard in the existing `sux` Grafana folder,
alongside `sux-metrics-prom` and `sux-resilience-obs`. Cloudflare Workers observability
is *linked* via deep-links, not rebuilt. This unifies edge + fabric health under one
Grafana folder.

### Ground truth
The collector also emits `fabric-status.json` (committed/artifacted each run) so the
`orient` CLI tool and the Grafana dashboard read **one** source and can never disagree.
This directly attacks the "two sources disagree" class of fire (stale clones, stale
SRC_MAP, audit-vs-origin drift).

## Workstreams (sequenced)

### WS1 — Spine (instrument)
Build collector → ship → surface + `fabric-status.json`. Capture the baseline.
Deliverable: one Grafana dashboard shows fabric health; `orient` reads the same JSON.

### WS2 — Root-cause sweep (fix, data-driven)
Walk the known incident classes, each confirmed against live spine data:
- structured-output failures (fixer/triage/issue-build/security-review)
- drain stalls / five-hour rate-limit false-reds
- disabled-required-check jams and path-filtered required-check jams
- author-association starvation (App token lacks org members:read)
- proxy empty-body failures

For each: reproduce → root-cause → structural fix → fold the lesson into
`CLAUDE.md`/docs → add a spine signal that catches a recurrence. Freeze only if a fix
cannot be done live.

### WS3 — Legibility (codify)
Capture the fabric's invariants and failure-modes as docs: what each workflow
guarantees, the required-check contract, the identity model (human vs bot), the budget
doctrine. Consolidate the scattered design docs into one coherent v2 fabric map.

## Success-criteria mapping

| DoD | Delivered by | Measured as |
|---|---|---|
| Dashboard | WS1 | "SuxOS — fabric health" renders; `fabric-status.json` exists |
| Drains unattended | WS2 | `suxos_drain_streak_days` ≥ 7 |
| Edge services green | WS1 + WS2 | edge deploy + runtime rows green |
| Fabric legible | WS3 | invariants doc exists; new-session orient needs no tribal knowledge |
| No recurring fires | WS2 | each incident class has a root-cause doc + a spine signal |

## Reconciled roadmap (coarse, forward-looking)

Deliberately low-resolution: each stage is a direction, not a task list. Detail is
pulled forward only when a stage starts, and only for that stage. The spine (S1) is the
hinge — everything after it is chosen from data the spine produces, not guessed now.

**Phase 1 — Stability (this spec)**
- **S1 Spine** — instrument the fabric (collector → Grafana push → dashboard +
  `fabric-status.json`). The one stage worth building carefully; everything else reads it.
- **S2 Root-cause sweep** — burn down the known incident classes against spine data.
  Sized by what the baseline shows red, not by a fixed list.
- **S3 Legibility** — codify invariants + failure-modes; consolidate the design docs
  into one v2 fabric map.
- **Exit:** DoD met — 7-day unattended drain streak, edge green, dashboard live, no
  recurring fires.

**Phase 2 — Next arc (own brainstorming cycle, seeded by the spine)**
Candidate directions, to be chosen from S1 baseline data rather than committed now:
- **Scale the unit of autonomous work** — from single-repo issues to multi-repo /
  larger units, once drain is reliably zero and there's headroom on the dashboard.
- **Self-direction** — the pipeline choosing *what* to work on (prioritization) rather
  than only draining a queue, guided by the health signals S1 exposes.
- **Edge platform growth** — new `sux` capabilities, now that its reliability is
  measured and green.
- **Budget/cadence tuning** — optimization proper, deferred out of Phase 1, informed by
  real utilization series from the spine.

The reconciliation: Phase 1 does not just stabilize — it produces the *measurement
surface* that makes Phase 2's direction a data decision. We open the Phase 2 cycle when
S1's baseline is clean, and pick the arc the data argues for.

## Out of scope (anti-early-optimization)

- Grafana metric history graphing beyond what the dashboard needs, custom alerting rules
- The Phase 2 rearchitecture and any new pipeline *capabilities*
- Rebuilding Cloudflare observability (linked, not rebuilt)

Phase 1 is convergence to reliable + legible + observable. Phase 2 (the next
development arc) is seeded from what the spine baseline reveals, and brainstormed as its
own cycle after WS1–WS3 land.
