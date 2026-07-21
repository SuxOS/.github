# SuxOS automation structure & anti-drift architecture

Status: adopted 2026-07-17

The whole point in one sentence: **work happens in the cloud, where it can't collide;
local routines only check it and push it forward.** This doc names every automation layer,
what knob it exposes, and the one rule that keeps parallel work from drifting.

## The two planes

### Cloud plane — where WORK happens (the "big fat pipeline")
The GitHub Actions three-loop pipeline (`SuxOS/.github`, reusable `workflow_call` library)
is the workhorse. Every unit of work is an **issue → built in an isolated, ephemeral CI
runner → PR → automerge**. No two builds share a filesystem, so the cloud plane is
drift-free by construction. Loops:

| Loop | Reusable | Cadence knob | What it does |
|---|---|---|---|
| collate-build | `issue-build.yml` | per-repo caller cron (hourly, staggered) + `issues:[labeled]` event | Grabs top-priority issues, one builder, one PR |
| green-merge | `automerge.yml` | event on green non-draft non-hold PR | Merges |
| red-rebase | `pr-auto-update.yml` / `pr-unstick.yml` | push:main + cron backstop | Auto-rebases behind/conflicting PRs |
| propose (3-tier) | `fixer.yml` | 15m bugs / 30m bugs+feats / 1h deep (standardized org-wide 2026-07-17) | Files new bugs/features as issues |

**Model & effort knobs (setpoint updated 2026-07-21 — SONNET-FIRST + effort-gating):** the
operator moved the setpoint from the 2026-07-17 "sonnet pinned org-wide, no Opus escalation"
to **sonnet-first, opus-on-fail** with **minor/easy ungated, everything else human approval**.
Concretely:
- **Default:** the auto-lane builds small/medium issues on **Sonnet + medium** reasoning
  effort. `model-hint` default stays `sonnet`.
- **`effort:large` is GATED to human approval** — added to the shared `nonbuildable-labels`
  floor, so large work of ANY type (incl. bugs) is NOT auto-attempted; it stays open for a
  human go-ahead. Rationale: a large issue just exhausts the Sonnet turn cap and ends up
  `needs-human` anyway, so gating it open is strictly cheaper than escalating. (Ordering
  within the auto-lane is unchanged — still bugs-first.) Visibility of *why* a gated issue
  isn't building is the separate #628 "why isn't this building" explainer.
- **Opus-on-fail (RATIFIED; implementation pending — F2b):** a build that fails specifically
  on **turn-cap exhaustion** (`error_max_turns`) gets a bounded **ONE Opus + high** retry.
  NOT a blanket escalation and NOT a retry on other failures — a real test/security rejection
  is a correct outcome and must not be retried. Deferred out of the F2a/setpoint PR because a
  correct retry must re-use the full build prompt/contract (safety rules + disposition schema)
  whose clean reuse needs a prompt refactor off the hot path, not a small additive change; the
  spoof-resistant turn-cap *detection* (structural match on the stream-json result message,
  never a text grep — cf. `classify-security-noverdict.sh`) is ready to build.

The older tier-sensed `model-hint: auto` escalation (opus on the HIGH tier) remains opt-in
per caller. effort otherwise auto-scales from tier, bumped one notch org-wide 2026-07-15.
This policy is single-sourced in [`.github/model-policy.json`](../../.github/model-policy.json)
and gated by `scripts/test-model-policy.sh`. `max-turns`/`scope` per fixer tier.
`budget-governor.yml` writes a `level:` line into each repo's "Autonomy throttle" issue;
`check-throttle` stands workloads down under budget pressure (defer-at: yellow). Headroom
target and cadence math live in [`budget-and-cadence.md`](budget-and-cadence.md).

### Local plane — orchestration only (the "routines that push it forward")
Scheduled tasks on the operator's machine. They do NOT do the work; they assess the cloud
plane, keep it unjammed, and advance the release cadence.

| Routine | Cadence | Role |
|---|---|---|
| `suxos-production-driver` | every 15m | Assess → reconcile drift → drain-check → advance release cadence (autonomous minors, operator-gated majors) → render the cadence ladder |
| `suxos-feature-brainstorm` | 2h | Divergent feature ideation → FEATURE-IDEAS.md (human-gated) |
| `suxos-ledger-consolidator` | nightly | Dedup ledgers; auto-graduate ≤1 feature/day into an issue |
| `suxos-graduate-ready` | manual | File `[ready]`-marked ledger items as issues |

Local routines run on this app's scheduled-task model (no per-task model selector exists in
the tool — uniform, not individually tunable).

## The anti-drift rule (the reason this doc exists)

**Never run two mutating processes in the same working directory.**

Root cause of the 2026-07-17 incident: two background agents were dispatched against the
SAME shared checkout (`~/Code/SuxOS/suxos-net`) and edited the same new files at once,
producing two PRs (#34, #35) that each carried a divergent/duplicate copy of `src/auth/*`.

Enforcement, in priority order:
1. **Prefer the cloud plane.** The default way to get work done is to file an issue and let
   the pipeline build it in an isolated runner. Two cloud builds can't collide. Reach for a
   local agent only for work the cloud genuinely can't do (a conflict reconcile, an
   emergency jam-fix).
2. **When local mutation is unavoidable, isolate it.** Every mutating operation gets its
   own fresh clone or `git worktree` under `/tmp`, one per task. A subagent doing mutation
   work is told, in its prompt, to work in a fresh isolated clone and leave no uncommitted
   state in any shared path.
3. **The shared `~/Code/SuxOS` checkout is read/orchestration only** — never a
   parallel-write surface.
4. **The production-driver detects the collision signature every run:** two open PRs that
   add/edit the same new files → hold the non-canonical one as draft, rebase it onto the
   canonical owner so it carries only its own files. Never let two PRs land divergent
   copies of one file.

This rule is also encoded in `suxos-production-driver`'s SKILL (RECONCILE step + Hard
rails) so it survives across sessions, not just in this doc.
