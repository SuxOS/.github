# SuxOS vX — the next arc (reconcile v2 to done, let the spine pick v3)

> **Status:** adopted. This document IS the "Phase 2 — Next arc" brainstorming cycle that
> [`2026-07-16-fabric-stability-v2-design.md`](2026-07-16-fabric-stability-v2-design.md)
> scheduled ("own brainstorming cycle, seeded by the spine").
> **Method:** full-org reconciliation audit, 2026-07-16 — three parallel surveys
> (`.github`@origin/main, all product repos@origin/main, live GitHub org state), diffed
> against the local workspace and the design corpus. Every divergence found is either
> **landed**, **seeded**, or **parked with a decision record** below. Nothing is left
> silently dangling.
> **Owner:** m@colinxs.com.

## 1. What "vX" means

vX is not a version number — it is the **standing next-arc mechanism**. Each arc ends the
same way: reconcile the previous arc to *done* (no dangling ends, docs match reality,
lessons encoded as mechanism), then choose the next arc **from measurement, not mood**.
This document does that for the current arc and defines the decision rule for the next.

The current arc ("v2") is two halves, both shipped in walking-skeleton form on 2026-07-16:

- **Product v2 — the op engine.** One authoring surface, graduated runtime
  (`runInline` / Cloudflare-Workflows `runDurable`), claim-check handles, control
  primitives. Spec: `sux/docs/superpowers/specs/2026-07-15-suxos-v2-op-engine-design.md`;
  shipped as sux#640 (walking skeleton), suxlib#1 (slice-3 reconcile modes),
  suxlib#2 (slice-5 governor primitives), suxlib#5 (fileops absorption).
- **Fabric v2 — stability.** The three-loop pipeline hardened + the S1 fabric health
  spine. Spec: [`2026-07-16-fabric-stability-v2-design.md`](2026-07-16-fabric-stability-v2-design.md);
  shipped as .github#266 + the 07-15/07-16 hardening burst (#242–#277).

The audit found the arc is ~90% landed but frayed at the ends: merged-but-unwired code,
stranded commits, a retirement half-done, docs pointing at repos that don't exist, and
paused loops with no expiry. vX's first move is to finish, not to start.

## 2. Reconciliation ledger

Every divergence the audit surfaced, with its disposition. **Land** = merged to `main`
this cycle (production: `sux` main auto-deploys; `.github` main is the live pipeline).
**Seed** = filed as a pipeline issue. **Park** = decision recorded, human step flagged.

| # | Divergence (evidence) | Disposition |
|---|---|---|
| R1 | Local clones sit on stale **already-merged** branches (`sux`→#640, `suxlib`→#1) — exactly the audit-against-origin/main trap. | **Land** (hygiene): normalize all clones to `main`, prune gone branches. |
| R2 | Uncommitted `sux` docs sweep renames the vault to `SuxOS/suxvault` — **a repo that does not exist**. Live truth: the vault is `colinxs/obsidian-vault` (pushed today). Docs must not lead reality. | **Park**: preserve the sweep on branch `docs/suxvault-rename-parked` (no PR); decision item below (§8-D1). |
| R3 | Commit `0baa168` ("wire sux edge health into panel 8, suxos.net/mcp=401") stranded on a gone branch — PR #268 landed only its sibling commit. Main's dashboard has no edge-health panel. | **Land**: K3 rescue PR to `.github`. |
| R4 | `sux` main's durable interpreter hardcodes `faithfulUnion` (durable.ts) while `suxlib` main ships `last-write-wins` + `field-merge` — a durable run of a moded op **silently degrades to faithful-union**. The slice-3 spec explicitly left this wiring as sux's follow-on. | **Land**: K1 — wire `runReconcile` dispatch + test. |
| R5 | **Loop 3's autofix rung is dead org-wide at the caller level.** .github#263 made the reusable `workflow_call`-only (job-chained from the caller's `ci.yml`), but `sux`, `suxrouter`, `suxlib` all still carry the dead `workflow_run` stub and **no** caller chains it — hence the `startup_failure`s (suxlib#7, class .github#51) and a red-rebase loop that structurally never fires. | **Land**: K2 — adopt the documented job-chain in all three callers, delete the stubs. |
| R6 | `sux-fileops` is retired in docs ("kept read-only for history") but **the pipeline still builds on it** (bot PRs #95–#108 merged today) — it is in `managed-repos.json` and runs its own fixer/issue-build crons. Retirement without de-registration. | **Land**: K4 — remove from `managed-repos.json` + strip its autonomy caller stubs. **Park**: actual archive is admin (§8-D2). |
| R7 | sux#452 ("generalized work framework — queued/batched jobs", on `hold`) is **superseded** by the shipped op-engine (the spec it asked for exists and runs). | **Land** (issue hygiene): close #452 with a supersession comment linking the spec. |
| R8 | Vision fragmentation in `sux`: `PLAN.md` (superseded), `docs/proposals/SUX.md` (current pivot), `docs/proposals/ROADMAP.md` (parked), `north-star.md` (living), pivot-validation (GO-with-conditions) — three identities for one repo, no canonical reading order. | **Seed**: one docs PR adding a supersession/reading-order banner set (bot-buildable). Canonical order recorded in §5. |
| R9 | `self-fixer`, `self-fixer-hourly`, `self-pr-drain`, `self-pr-watch` on `.github` are `disabled_manually` with **no expiry and no tracking** — the exact stale-incident-override class already burned twice. | **Land**: re-enable `self-pr-drain` + `self-pr-watch` (hygiene loops) once this cycle's PRs merge. Fixer inflow stays paused **with a tracking issue + expiry condition** (§8-D3). **Seed**: spine signal `suxos_workflow_disabled` so the class is caught by dashboard, not memory. |
| R10 | Two bot PRs are self-held on real high findings (.github#276, suxrouter#259) — the drain is waiting on finding-resolution. | **Land**: resolve findings on both (fix code, then unhold), via owning subagents. |
| R11 | Session memory says the vault repo moved to `SuxOS/vault` — false against live GitHub. | **Land** (meta): correct the operator's memory files this session. |
| R12 | `delete_branch_on_merge` drift (false on suxlib/claude-config/sux-fileops) accumulates stale bot branches. | **Seed**: fold into the existing config-drift audit issue .github#202 as a concrete case; no new issue. |

## 3. Completion keystones (built to production this cycle)

- **K1 — `sux`: durable reconcile-mode dispatch.** `durable.ts` reconcile case delegates
  to suxlib's `runReconcile(node.opts, input, caps.store)`; unit test proves a
  `last-write-wins` op selects by `producedAt` under the durable interpreter. Closes the
  R4 silent-degradation hazard and completes slice 3 end-to-end.
- **K2 — Loop 3 org-wide: autofix job-chaining.** In `sux`, `suxrouter`, `suxlib`:
  add the `autofix` job to each `ci.yml` per the pattern documented in the reusable's
  header (needs the gate job, `if: result == 'failure' && event == 'pull_request'`,
  explicit PR-identity inputs, `secrets: inherit`); delete the dead `claude-autofix.yml`
  workflow_run stubs. Closes suxlib#7 concretely and the #260/#263 migration debt; the
  red-rebase loop becomes real for the first time.
- **K3 — `.github`: spine panel-8 rescue.** Re-land `0baa168` (sux edge health →
  dashboard panel; collector probes `suxos.net/mcp` expecting 401) on a fresh branch.
  Completes S1's "edge services green e2e" visibility (fabric DoD #3).
- **K4 — `sux-fileops` de-registration.** Remove from `.github/managed-repos.json`;
  strip the repo's own fixer/fixer-hourly/issue-build/claude-autofix/pr-* caller stubs
  (keep ci/security-review/automerge so the stripping PR itself can land). The pipeline
  stops spending on a retired repo.

## 4. The next-arc decision rule (Phase 2, made mechanical)

The fabric doc was right to refuse to pick an arc before the spine had data. vX encodes
**how the data picks**, so the choice is a reading, not a re-litigation. Gate first:

> **Gate:** fabric DoD #2 — backlog drains to zero unattended and stays there **7
> consecutive days** with the spine green (no `suxos_*` red panels, no `needs-human`
> pile-up), fixer inflow re-enabled for at least the last 3 of those days.

Then read the baseline and take the **first row that matches**:

| Spine baseline says | Next arc |
|---|---|
| Drain green + opus bucket ≥50% idle headroom sustained | **Scale the unit of autonomous work** — multi-repo / epic-sized issues (sux#228 decomposition becomes the test case). |
| Drain green but headroom <50% (spend-bound) | **Budget/cadence tuning** — governor v2 (#274/#275 line), model-tier rebalance, cadence math from real series. |
| Backlog refills faster than drain (inflow-bound) | **Self-direction** — the pipeline prioritizes *what* to build (value-ranking over FIFO tiers), guided by spine signals. |
| Edge panels burn error budget (suxos.net probes red) | **Edge reliability arc** — suxrouter/egress contract first (§5 slice 6). |
| Baseline never stabilizes (7-day gate keeps failing) | The arc is **more stability** — WS2 root-cause sweep continues; no new capability work. |

The rule itself is revisable — but only by editing this table in a reviewed PR, not by
vibes in a session.

## 5. Product slice ladder, reconciled

Canonical reading order for `sux` vision docs (R8): **`north-star.md`** (principles,
living) → **`docs/proposals/SUX.md`** (current thesis: git-markdown knowledge core) **as
amended by `docs/design/pivot-validation-2026-07.md`** (GO on the store, NO-GO on the
"just markdown + verbs" slogan; the core includes a query/index/integrity layer) →
**op-engine spec** (execution architecture). `PLAN.md` and `docs/proposals/ROADMAP.md`
are historical (superseded / parked with re-triggers).

| Slice | State | This cycle |
|---|---|---|
| 1–2 op-engine walking skeleton | **Shipped** (sux#640) | — |
| 3 reconcile conflict modes | **Shipped lib-side** (suxlib#1); durable wiring missing | **K1 lands it** |
| 4 vault query/index layer | Open — pivot-validation GO-condition 1a calls the task-aware index "the single highest-leverage add"; conditions 2 (write-sha + append/edit retry) small and adjacent | **Seed** as the next product keystone issue |
| 5 governor | Primitives shipped (suxlib#2); algorithm reconciled into `budget-governor.yml` (see budget-governor-reconciliation.md); #274/#275 in flight | Already moving — no new work filed |
| 6 egress contract (`sux` ↔ `suxrouter`) | Prose-only seam (design docs on one side, ucode on the other) | **Seed**: typed contract + conformance check issue |

## 6. Invariants (lessons → mechanism, not memory)

1. **A manual `disabled_manually` needs an expiry.** Any hand-disabled workflow gets a
   tracking issue naming the re-enable condition; the spine exposes
   `suxos_workflow_disabled{workflow=…}` so the dashboard catches what memory forgets. (R9)
2. **Docs may not lead reality.** A doc referencing a repo/binding/URL that doesn't exist
   is a red finding for the org-consistency sweep, not a style choice. (R2)
3. **Retire = de-register.** A repo isn't retired until it's out of `managed-repos.json`
   and its autonomy callers are stripped; "read-only for history" must be mechanically
   true (archive) or it isn't true. (R6)
4. **Audit against `origin/main`, never the working tree** — local checkouts lie; the
   stale-merged-branch trap recurred this cycle. Normalize clones after landing work. (R1)
5. **A merged reusable-workflow migration isn't done until every caller adopts it.**
   #263 sat "fixed" for hours while all three callers stayed dead. Migration PRs in
   `.github` must enumerate callers and seed the caller PRs in the same motion. (R5)

## 7. Seeded backlog (filed this cycle)

1. `sux`: slice-4 vault keystone — task-aware index + `write` base_sha + append/edit
   bounded retry (pivot-validation GO conditions 1a + 2), git-only backend, measured at
   1k–5k notes.
2. `sux`: docs supersession banners + canonical reading order (R8).
3. `.github`: `suxos_workflow_disabled` spine signal + dashboard panel (R9/invariant 1).
4. `.github`: egress contract slice-6 spike — extract the residential-egress contract
   from prose into a typed, conformance-checked interface between `sux` and `suxrouter`.
5. `.github`#202 comment: `delete_branch_on_merge` drift as a concrete audit case (R12).

## 8. Decisions recorded (parked, human-gated where admin)

- **D1 — vault home.** The `SuxOS/suxvault` rename sweep is parked until the repo
  transfer actually happens (admin: GitHub transfer of `colinxs/obsidian-vault` +
  `OBSIDIAN_VAULT_REPO` secret rotation + docs sweep — the parked branch). Until then
  every doc keeps saying `colinxs/obsidian-vault`, because that is what production uses.
  Filed `needs-human`.
- **D2 — `sux-fileops` archive.** After K4 de-registration, archiving the repo (making
  "read-only for history" mechanically true) is one click that only the owner should
  take. Filed `needs-human`.
- **D3 — fixer inflow.** Stays paused until this cycle's PRs land and the held PRs
  (R10) resolve; the tracking issue carries the re-enable condition ("backlog at zero,
  no `hold` PRs open"). The hygiene loops (`self-pr-drain`, `self-pr-watch`) do not
  wait — they re-enable with this cycle.
- **Declined:** starting a Phase-2 capability arc now (violates §4's gate);
  entity-resolution reconcile modes (closed with evidence in the slice-3 spec);
  merge queue, multi-builder parallelism, and the rest of three-loop §8's declined
  levers (unchanged, re-triggers stand).

## 9. Out of scope

The Phase-2 arc build itself (gated, §4); the vault VPC backend (sux#419, its own
track); MCP surface refactor (deferral re-confirmed in the slice-3 spec); anything
requiring org-admin actions beyond the two `needs-human` decisions above.
