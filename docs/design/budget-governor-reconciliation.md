# Budget-governor reconciliation — suxlib's control primitives vs. this repo's live governor

Date: 2026-07-16. Status: adopted (this PR). Reconciles `suxlib`'s slice-5 governor
primitives (`suxlib` PR #2, `docs/superpowers/specs/2026-07-16-slice5-governor-primitives-design.md`
in that repo) with this repo's already-live `budget-governor.yml`
(`docs/design/budget-and-cadence.md`). Short note, not a new spec — both systems are
already designed; this is the seam between them.

## The two systems are not the same system

They are namesakes ("governor," "budget") describing genuinely different mechanisms,
at different layers, governing different resources, in different runtimes:

| | `suxlib`'s `control/*` primitives | `budget-governor.yml` (this repo) |
|---|---|---|
| **Runtime** | In-process TypeScript, runs inside a single Cloudflare Worker/Workflow invocation | Bash/jq on a GitHub Actions runner, scheduled every 6h |
| **Lifetime** | Lives and dies with one op-engine request | Stateless between runs; recomputes from GitHub's API each tick |
| **Resource governed** | Rate/concurrency/failure of calls to *one* external dependency *within one request* (a `map()` fan-out's calls) | Aggregate CI runner-minutes across the *whole org* over a *trailing week* — a proxy for Max-20x subscription spend |
| **Consumer** | The op leaf's own control flow (`if (!breaker.allow(now)) throw ...`) | Other scheduled GitHub Actions workflows, via the `check-throttle` composite reading a `level:` line in a GitHub issue |
| **State** | In-memory (closures over `tokens`, `state`, `inflight`) | Externalized to GitHub issues (the only "storage" a bash workflow has) |

The disqualifying fact for any "wire suxlib in" reading of Slice 5: **a GitHub Actions
`run:` step cannot `import` a TypeScript library.** There is no runtime in which
`tokenBucket()` as shipped in `suxlib` PR #2 executes inside `budget-governor.yml`.
Any reconciliation that starts from "swap the primitive in" is not executable and was
never on the table — `suxlib`'s own spec (§1.3, §7) already anticipated this and
explicitly declined to touch `.github` or the live throttle system, flagging exactly
this seam for later, separate work. This document is that later work.

**Conclusion: the two systems stay separate.** Neither replaces nor subsumes the
other. `suxlib`'s primitives remain library code with zero consumers today (per its
own §6, wiring them into an op leaf is deferred, unrelated to this repo). This repo's
`budget-governor.yml` keeps governing what it already governs: cross-repo, weekly,
CI-spend-proxy cadence throttling. If a future op leaf inside the `sux` Worker needs
to pace its own concurrent calls to an external API *within a single request*, that's
what `suxlib`'s `tokenBucket`/`circuitBreaker`/`aimd` are for, and it is a wholly
separate integration with its own future PR — it has nothing to do with this repo.

## What *does* carry over: the algorithm, reimplemented, not imported

While the code can't move, the underlying control-law idea can — and it exposes a
real weakness in `budget-governor.yml`'s current logic that's worth fixing on its own
merits, independent of `suxlib`'s existence.

**Current algorithm (before this PR):** sum wall-clock runner-minutes for
Claude-tagged workflow runs over a trailing 7-day window; compare the sum to a fixed
budget; flip yellow at 75%, red at 100%. This is a **cliff-edge sliding-window sum**,
and it has a real, observable failure mode: **it is blind to the shape of spend within
the window, but very sensitive to the window's hard edge.**

- Two spend patterns with the *same trailing-7-day total* — a burst crammed into the
  last hour vs. the identical total spread evenly across the whole week — produce the
  *identical* throttle level under the old algorithm, even though only one of them
  represents an actual ongoing risk. (Verified below.)
- A single burst gets "baked in" for the *entire* window regardless of what happens
  afterward. If automation bursts early in the week and then goes completely quiet,
  the old algorithm holds the org at yellow/red for up to a full 7 days — not because
  spend is still elevated, but because the burst hasn't yet aged out of the fixed
  window. Recovery is a function of calendar time since the burst *entered* the
  window, not of calendar time since spend actually *dropped*.

**New algorithm (this PR): a token bucket, replayed statelessly from the same event
data.** Each tier (`opus`, `total`) gets a bucket: capacity = that tier's existing
`*_BUDGET_MIN`, continuous linear refill at `budget / (LOOKBACK_DAYS * 1440)` per
minute — i.e. spend at exactly the budgeted *average* rate never drains it. Every 6h
tick, the same trailing-window run list the sweep already fetches is replayed in
chronological order as a sequence of discrete debits (each run's wall-clock minutes,
at its completion time) against that bucket, with refill applied for the elapsed time
between debits. The throttle level is then read off the bucket's **current available
headroom** (yellow when either bucket drops to ≤25% capacity, red at ≤0), not off the
raw trailing sum. No new persisted state is introduced — the bucket's entire
trajectory is deterministically recomputed from the event list on every run, matching
the workflow's existing fully-stateless design.

This is the same *shape* of idea `suxlib`'s `tokenBucket()` implements and validated
by simulation (capacity + continuous refill, replacing a binary threshold) — grounded
independently here, not by importing code, because bash/jq has to reimplement the
math from scratch regardless. It is adopted on its own merits: it fixes a concrete,
demonstrated weakness in the existing algorithm, using data the workflow was already
collecting.

**What is explicitly unchanged:** the `*_BUDGET_MIN`/`YELLOW_FRACTION`/`LOOKBACK_DAYS`
inputs keep their existing meaning and the same calibration ritual
(`docs/design/budget-and-cadence.md`) still applies — a bucket at capacity `X` with
refill tuned to `X` over the window behaves identically to the old sum-vs-`X`
threshold for *steady* spend; the two algorithms only diverge on bursty spend, which
is exactly the case the old algorithm handled badly. The observable outputs — the
per-repo "Autonomy throttle" issue's `level: green|yellow|red` line, the org-wide
report issue, the `check-throttle` composite's contract — are unchanged in shape.
Only the internal computation of `level` changed.

## Empirical comparison (synthetic, run locally before this PR touched the live workflow)

Same event data, same budgets (opus 900/wk, total 6000/wk, yellow at 75%), fed through
both the old sum-vs-threshold logic and the new bucket logic:

**1. Burst then quiet** — 5500 runner-min crammed into the first 30 minutes of the
window, then nothing:

| day since burst | old level | new level | bucket headroom |
|---:|---|---|---:|
| 0.05 | yellow | yellow | 583/6000 |
| 1 | yellow | yellow | 1397/6000 |
| **2** | yellow | **green** | 2254/6000 |
| 6.9 | yellow | green | 6000/6000 |
| 7.01 (burst ages out of window) | green | green | 6000/6000 |

Old logic holds yellow for the full week regardless of the 6.9 days of subsequent
silence. New logic self-heals to green within 2 days — the level tracks *current*
risk, not stale history.

**2. Same trailing-window total, different shape** — 5000 runner-min, measured at the
same instant, two distributions:

| distribution | old level | new level | bucket headroom |
|---|---|---|---:|
| last-hour burst | yellow | **yellow** | 1076/6000 |
| spread evenly across 7 days | yellow | **green** | 6000/6000 |

This is the exact failure mode named above, confirmed: the old algorithm cannot tell
these apart (identical trailing sum → identical level); the new algorithm correctly
flags the burst and clears the evenly-spread pattern, which never posed real risk.

**3. Steady legitimate usage (regression check)** — 5500 runner-min spread evenly
across 14 days (well under the sustainable rate): both algorithms agree — green
throughout the entire tested range (day 0 through day 14). No new false positives on
ordinary usage.

(Test harness: synthetic `gh run list`-shaped fixtures + the exact jq program later
embedded in `budget-governor.yml`, run standalone via `jq -f`, sweeping the "as of"
check time across each scenario. Not committed to the repo — this was an offline
validation pass per this repo's `CLAUDE.md` ("get the math right offline first"), not
a permanent test suite; `actionlint` plus the existing `self-check.yml` invariants are
the ongoing gate on this file.)

## Non-goals of this PR

- Not wiring any `suxlib` code into this repo — impossible across the TS/bash
  boundary, and out of scope regardless (see table above).
- Not changing `check-throttle`, the per-consumer throttle semantics table
  (fixer/triage/issue-build/deep-audit/org-consistency/security-review), the
  merge-gates-are-never-throttled invariant, or `managed-repos.json`.
- Not changing the *numeric* budgets (`OPUS_BUDGET_MIN`, `TOTAL_BUDGET_MIN`,
  `YELLOW_FRACTION`, `LOOKBACK_DAYS`) or the calibration ritual — only how `level` is
  derived from them.
- Not a decision about whether `suxlib`'s primitives should ever be wired into a
  pipeline workflow. If that need arises later, it would run inside a Worker calling
  out to GitHub (or some other in-process context), not inside this bash workflow —
  a different, separately-scoped integration.
