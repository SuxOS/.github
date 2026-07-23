# Pipeline invariant registry — design

> **Status:** design/spec only — no code in this doc.
> **Trigger:** brainstorming session on recurring pipeline failure classes, converging
> two motivating incident sets: (1) named postmortems accumulated in the user's global
> CLAUDE.md — required-check jams, DIRTY zombie PR claims, stale incident-response
> overrides, structured_output no-verdict, budget-governor blind spots — each patched
> individually as found; (2) a live incident hit *during this same session*: `self-
> issue-build.yml` livelocked for 8+ hours (2026-07-22 20:18 UTC – 2026-07-23 04:23+
> UTC), 28 consecutive runs cancelled at the 30-minute job timeout, ~868 runner-minutes
> burned, zero PRs landed, tracked as #701. A same-day interim mitigation (shrinking
> `max-issues`/`effort-budget`) was already tried and silently failed for 6+ hours
> before anyone noticed. Emergency response taken during this session: `gh workflow
> disable "Self issue build"` + cancel the two in-flight runs (both confirmed; see
> session transcript). The concrete #701 fix (shrink-on-retry circuit breaker, plus a
> requeue double-dispatch race also found in the run history) is tracked as its own
> follow-up, not part of this doc — this doc is about making the *next* incident like
> it visible in minutes instead of hours, not about fixing this specific bug.

## 1. Problem

Three failure shapes recur across this pipeline's history, each currently caught by a
human noticing (or a bespoke one-off script written after the fact):

1. **Drift** — a declared source-of-truth silently diverges from live reality.
   `check-settings-drift.py` is the one instance that got a real watcher; the same
   shape is unwatched elsewhere (`managed-repos.json` missing `suxos-net`/`nix`, #689;
   Fixer caller-stub display names lying about actual cadence, #690).
2. **Never-self-heals** — state meant to be temporary (a `hold`/`throttle-manual`
   pin, a disabled-but-required check, a DIRTY zombie PR claim) has no expiry and
   persists until a human happens to look.
3. **Silent-green / effect-not-verified** — a step reports success without verifying
   its claimed effect actually landed (`fabric-health` green while the Grafana push is
   dark, #694; `structured_output` no-verdict; security-review fail-open-on-cancel).

Tonight's #701 incident turned out to be expressible in the *same* taxonomy rather
than needing a fourth category — see §3.

## 2. Architecture

Extend `fabric-health.yml` (already scheduled every 15 min via `self-fabric-health.yml`,
already pushes to the `suxos-fabric-health` Grafana dashboard, already feeds the
needs-human panel per #659/#660) with a new step that runs an **invariant registry**: a
set of small checks, each returning OK/WARN/CRIT, of three kinds:

- **`drift`** — declared vs. live comparison. Generic enough to be pure data (a
  manifest entry), no code per check.
- **`ttl`** — a recorded state's age/attempt-count vs. its own expiry/bound. Also
  expressible as pure data.
- **`effect`** — did a claimed action's real effect actually happen. Inherently
  specific; each is a small script against a fixed contract.

Where a `drift` check would just watch a hand-maintained list that could instead be
*generated* from live state, generate it and skip the check entirely (prevention over
detection where it's free) — e.g. `managed-repos.json` becomes a query against
`gh repo list --org SuxOS` filtered by an explicit inclusion rule, rather than a
hand-edited file #689 already caught drifting.

No new subsystem: this reuses infrastructure the pipeline already trusts and already
keeps alive, rather than adding a second thing that itself needs watching.

## 3. Check kinds, with concrete entries from both motivating incident sets

| Kind | Entry | Declared | Live | Motivating incident |
|---|---|---|---|---|
| `ttl` | retry-bound circuit breaker | a batch attempt resolves (success or explicit give-up) within N consecutive tries | consecutive cancelled-on-timeout runs of the identical workflow | #701 — 28 consecutive identical-timeout retries, no bound |
| `effect` | cost-effectiveness | runner-minutes spent on repo X should correlate with landed progress (merged PRs / closed issues) over the same window | spend continues, output stays at zero | #701 (broader signature than the ttl entry above — catches livelocks that aren't identical-batch-shaped too) |
| `drift` | managed-repos.json vs. live org state | repo list = `gh repo list --org SuxOS` minus explicit exclusions | hand-maintained `managed-repos.json` | #689 — cold-tier repos invisible to budget tracking |
| `drift` | settings.json vs. claude-config source | repo source of truth | live `~/.claude/settings.json` | already built (`check-settings-drift.py`); registry generalizes the pattern, doesn't replace the existing hook |
| `ttl` | stale override sweep | every `hold`/`throttle-manual`/disabled-required-check carries an expiry or explicit `permanent: true` | override age vs. its own recorded expiry | required-check jam variants, DIRTY zombie PR claims, stale incident-response overrides (all named in CLAUDE.md) |
| `effect` | fabric-health push verification | Grafana push HTTP call succeeding implies the metric is actually queryable | round-trip query confirms the pushed value landed | #694 — green while Grafana was dark |

#701 did not need a fourth kind: it's simultaneously a `ttl` violation (no retry
bound) and an `effect` violation (spend without output) — the two entries above are
deliberately redundant, since the `ttl` check catches this *specific* signature fast
and the `effect` check catches livelocks shaped differently than identical-batch retry.

## 4. Components

1. **`invariants/manifest.yml`** — declarative `drift` and `ttl` entries. A `drift`
   entry names `declared_source` and `live_source` (each a query/script producing a
   comparable set or value) and a diff mode. A `ttl` entry names where to find an
   override's timestamp/attempt-count and its bound, with an explicit `permanent: true`
   escape hatch for intentionally-standing state (e.g. the 1.1-drive project's "ALL
   drummers stay disarmed" pin — some overrides are meant to be long-lived, and the
   mechanism must not fight that).
2. **`invariants/effect/*.py`** — one script per effect check, fixed contract: exit
   0/1/2 (OK/WARN/CRIT), one-line message on stdout. Same shape existing hook scripts
   in this repo already use.
3. **`invariants/runner.py`** — loads the manifest, runs the generic drift/ttl
   comparison logic, discovers and runs the effect scripts, normalizes every result to
   `{id, kind, severity, status, message}`.
4. **Wiring** — new `fabric-health.yml` step runs the registry. CRIT results upsert
   (dedup by invariant id) into the existing needs-human rollup rather than a new alert
   path; OK/WARN/CRIT counts push to Grafana alongside existing fabric metrics.
5. **Contribution rule** — documented, and where practical lint-enforced the way
   settings/hooks/json checks already ride inside the required `shellcheck` job: a PR
   introducing a new temporary override or a new hand-maintained declared list must add
   a manifest entry, or state why generation made one unnecessary.

## 5. Auto-remediation (opt-in, bounded)

Detection alone shortens #701-shaped incidents from "8 hours until a human looks" to
"~15 minutes until the next fabric-health run" — a real win, but still leaves the
stop-the-bleed action to a human watching the panel. Tonight's actual fix (`gh workflow
disable` + `gh run cancel`) was fully mechanical: it needed no judgment about *why* the
livelock was happening, only that the `ttl` circuit-breaker invariant had tripped.

Proposed: an opt-in `remediate` field on `ttl`-kind manifest entries, v1 supporting
exactly one action — `disable-workflow`. Every auto-remediation always *also* writes to
the needs-human panel (never silent); re-enabling is always a manual
`gh workflow enable` once the underlying fix lands. No other action type ships in v1 —
no auto-merge, no config change, nothing touching `main` or secrets. This is
deliberately narrow: the action available is exactly the one already validated by
hand tonight, not a general "the registry can act" capability.

## 6. Data flow

```
fabric-health.yml (cron, every 15 min)
  → runner.py: load manifest + discover effect/*.py
  → for each check: run, catch exceptions, normalize result
  → ttl CRIT with remediate: disable-workflow → gh workflow disable (bounded, reversible)
  → all CRIT results: upsert into needs-human rollup issue (dedup by id)
  → all results: push OK/WARN/CRIT counts to Grafana (existing push path)
```

## 7. Error handling

A check that crashes (script error, API timeout) is caught by the runner and reported
as CRIT with the exception text — a check that can't run is a signal itself, never a
silent skip. This is a direct rule extracted from the `check-settings-drift.py`
self-symlink incident already in CLAUDE.md, where a fail-open hook died silently and
nobody noticed for an unknown span.

GitHub API calls inside checks route through the bot identity's token/GraphQL pool,
not personal-account REST calls, per the standing 5k/hr ceiling rule.

The meta-recursion question — "who watches the registry itself" — resolves for free:
"declared: fabric-health runs every 15 min" vs. "live: timestamp of its last successful
run" is just another `drift`-kind manifest entry, checked by the same primitive that
watches everything else. No second watcher to build or forget about.

## 8. Testing

Unit-test the generic drift/ttl comparison logic against fixtures, the way
`tests/fuzz_argv_canon.py` already tests the hook layer independently of production
constants. Effect checks get their contract (exit code + stdout shape) tested against a
mock, not a live external call. One deliberately-failing fixture proves CRIT actually
reaches the needs-human rollup end-to-end — a regression test for the alerting path,
not just detection. A second deliberately-failing `ttl` fixture with `remediate:
disable-workflow` set proves the remediation path fires against a disposable test
workflow, not a load-bearing one.

## 9. Explicitly out of scope for this doc

- The actual #701 fix (shrink-on-retry logic in `issue-build.yml`, and the requeue
  double-dispatch race also found in tonight's run-history data) — tracked as a
  separate follow-up task, not blocked on this design landing.
- `pin-consistency.yml`'s push+pull_request double-fire (structural trigger-hygiene
  waste, low severity/high frequency) — a real finding from tonight's survey, but a
  narrow config fix, not something the registry needs to model.
- The per-repo weighted budget share (#542, already spec'd in
  `2026-07-22-budget-governor-per-repo-weighting-spec.md`, not yet built) — orthogonal
  to invariant detection.
