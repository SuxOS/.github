# Budget & cadence redesign — targeting 80% of a Claude Max 20x subscription

Date: 2026-07-14. Status: adopted (this PR). Supersedes the model-per-stage table in
`backlog-pipeline.md` §"Model per stage" (updated in place there) and re-introduces a
budget control to replace the retired `budget-guard.yml` — smarter this time: tiered,
measured, and self-adjusting instead of a binary org-wide pause.

## The constraint

All Claude CI workflows authenticate with `CLAUDE_CODE_OAUTH_TOKEN` — the same Max 20x
subscription that serves interactive sessions. Max 20x carries (as of 2026-07):

- a **weekly all-models bucket** (~24–40 "Opus-hours"/week equivalent — the scarce resource;
  Opus burns it ~5x faster than Sonnet per wall-clock hour of work),
- a **weekly Sonnet-only bucket** (~240–480 hours/week — roughly 10x the headroom),
- 5-hour rolling session caps.

Anthropic no longer publishes fixed token numbers, so absolute budgeting is impossible —
the design is **feedback-controlled**: measure a spend proxy continuously, throttle
automation when the proxy exceeds thresholds, and calibrate thresholds against the
subscription's own usage page over time.

**Target: 80% total subscription utilization**, with automation yielding first — automation
throttles before interactive work ever feels a limit. Interactive sessions (typically
Opus/Fable) get first claim on the all-models bucket; automation's Opus share is capped.

## What the data showed (2026-07-08..15 baseline)

Peak days ran ~600–800 Claude-runner wall-clock minutes/day (~70–90 h/week). With
security-review, triage, and issue-build all on Opus, automation alone projected to
~2x the weekly all-models bucket, while the Sonnet bucket sat nearly idle. Waste hotspots:

| Hotspot | Evidence | Fix |
|---|---|---|
| Per-issue triage bursts | 77 executed Opus runs @ 4.6 min avg in 1.2 days — the per-issue concurrency group let parallel full-queue sessions race | Serialize triage (one static concurrency group) + move callers from `issues:` triggers to a 3x/day batch schedule |
| Per-PR Opus security review | ~175 executed runs/day across repos @ ~1.2 min | Gate moves to Sonnet; nightly Opus deep-audit compensates (see below) |
| Opus codegen in issue-build | Every build session on Opus despite CI + security-review + confidence gating downstream | `build-model` → Sonnet |
| skill-sync failure loop | 129/288 runs failed over 7 days | Filed as a pipeline issue (bug, not a parameter) |
| Burst cancellations | 23 cancelled issue-build runs in one burst | Scheduled batch triggers smooth the bursts |

## Model doctrine v2 — frequent-cheap, infrequent-expensive

The old doctrine put Opus wherever a judgment was high-stakes. The new doctrine adds a
second axis: **frequency**. High-frequency work runs on the cheap tier even when it gates,
and is compensated by a low-frequency deep pass on the expensive tier.

| Stage | Model | Frequency | Rationale |
|---|---|---|---|
| security-review (per-PR gate) | **sonnet** (was opus) | ~100+/day | Sonnet 5 is near-Opus on code review at ~1/5 the budget weight, and draws on the roomy Sonnet bucket. The unconditional CI gate, confidence labels, and the nightly deep-audit below are the compensating controls. |
| deep-audit (nightly, NEW) | **opus** | 1/day/repo, skips when nothing merged | Reviews the day's *merged* diff with fresh eyes — catches what the fast per-PR pass missed, files issues into the pipeline. |
| triage (confidence call) | **opus** (unchanged) | ≤3 batch runs/day/repo | Still the single judgment that lets code merge with no human review. Low frequency after batching, so Opus is affordable here. |
| issue-build: build | **sonnet** (was opus) | bursty, gated | Codegen is triple-gated (CI, security-review, confidence label set independently by Opus triage). |
| issue-build: cluster | sonnet (unchanged) | mechanical | |
| fixer (proposer) | sonnet (unchanged) | 1x/day (was 3x/day on sux) | Proposals queue behind triage/build throughput anyway; 3x/day just built backlog. |
| claude mention / review / autofix | sonnet (unchanged) | event-driven | Review already skips bot-authored PRs. |
| org-consistency (weekly, NEW) | **opus** | 1/week | Cross-repo consistency + refactor-opportunity sweep over all org repos; files issues into the pipeline. |

Projected automation Opus spend after redesign: ~450–500 runner-min/week (triage batches
+ nightly audits + weekly consistency pass) vs. a ~900 min/week automation budget
(≈ 50% of an ~1,800-min 80%-target all-models bucket, leaving the other half for
interactive). Sonnet spend (~2,500–3,500 min/week) sits far inside the Sonnet bucket.

## The budget governor

`budget-governor.yml` (scheduled in this repo, every 6h) is the feedback loop:

1. Sweeps `gh run list` across all org repos for the trailing 7 days (App token).
2. Rolls up wall-clock minutes for Claude-invoking workflows, split opus/sonnet by a
   workflow→model map kept in the workflow env (the same proxy caveat as
   `pipeline-utilization.yml`: wall-clock correlates with spend; it is not a bill).
   Known gap (accepted, not fixed): this map keys off the *workflow name* only.
   issue-build's build step (`.github/workflows/issue-build.yml`, `sensedOpus`, added
   in #172) adaptively escalates its *own* run to opus per-batch based on tier/labels —
   the workflow is still named "Issue build" either way, so those opus-escalated
   minutes land in `total_min` and never `opus_min`. Precise attribution would need
   issue-build to emit a distinguishable signal (distinct run-name/job-name per tier)
   that the governor's `gh run list` sweep can key off; not worth the complexity while
   opus escalation stays rare (high-tier or effort:large batches only).
3. Compares against two thresholds (workflow inputs): `opus-budget-min` (default 900/week)
   and `total-budget-min` (default 6000/week). ≥75% of either → **yellow**; ≥100% → **red**.
4. Upserts one org-wide report issue in this repo, and a per-repo tracking issue titled
   **"Autonomy throttle"** whose body carries `level: green|yellow|red` in every repo.
5. Skips overwriting any throttle issue labeled `throttle-manual` (manual override pin).

Consumers read the signal with the `check-throttle` composite action (their own repo's
issue, ambient `GITHUB_TOKEN`, zero cross-repo auth). **Fail-open**: no issue or an
unreadable one reads as green, so a governor outage never stalls the pipeline.

Throttle semantics — merge gates are never throttled (a red light must not jam the queue):

| Level | fixer | triage | issue-build | deep-audit | org-consistency | security-review / claude / autofix |
|---|---|---|---|---|---|---|
| green | runs | runs | runs | runs | runs | runs |
| yellow | skips | runs | runs | skips | skips | runs |
| red | skips | skips | skips | skips | skips | runs |

(Yellow defers the *deferrable* work — proposing new work and deep passes — while the
in-flight backlog keeps draining; red stops all scheduled Claude work.)

## Cadence table (caller-side, after this redesign)

| Workflow | sux | sux-fileops | suxrouter | Notes |
|---|---|---|---|---|
| fixer | `17 8 * * *` | `41 9 * * 1,4` | `22 8 * * *` | Daily (2x/week on low-activity fileops) |
| triage | `7 5,13,21 * * *` | `27 6,18 * * *` | `47 5,13,21 * * *` | Scheduled batch replaces per-issue trigger; `workflow_dispatch` for on-demand |
| issue-build | `7 2,8,14,20 * * *` | `37 3,15 * * *` | `57 2,8,14,20 * * *` | Scheduled batch replaces per-label trigger |
| pr-auto-update | `17 6 * * *` + push:main | same | same (was every 2h) | push:main is the real self-drain |
| deep-audit | — | — | — | Runs from this repo, nightly `33 3 * * *`, matrix over repos |
| org-consistency | — | — | — | Runs from this repo, weekly `47 6 * * 1` |
| budget-governor | — | — | — | Runs from this repo, `13 */6 * * *` |

Minutes are deliberately staggered across repos and offset from the top of the hour so
batch sessions don't collide inside one 5-hour subscription window.

## Calibration

The proxy thresholds are guesses until correlated with reality. Weekly ritual (or when the
governor first goes yellow): open claude.ai → Settings → Usage, note the weekly-bucket
percentages at the same moment the governor report was generated, and adjust
`opus-budget-min` / `total-budget-min` so governor-yellow lands at ~75% of the *actual*
bucket. Record adjustments in this file's history.

## Reverting

Every change is an input default or a caller cron — revert by overriding `model:` /
`build-model:` in a caller's `with:` block or restoring the old cron lines. The governor
is advisory-by-construction: delete the throttle issues and everything runs green.
