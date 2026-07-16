# Three-loop pipeline — design

Status: **Phases 0–3 shipped (2026-07-15), verified live 2026-07-16 — Loops 1 & 2 confirmed
working end to end; Loop 3's `claude-autofix.yml` rung confirmed BROKEN org-wide
(SuxOS/.github#260), the rest of Loop 3 mixed (see §6).**
Supersedes the eligibility/confidence machinery in
[`pipeline-eligibility-throughput-rework.md`](pipeline-eligibility-throughput-rework.md)
and [`backlog-pipeline.md`](backlog-pipeline.md) where they conflict. This is the target
shape; the migration is phased and reversible (§6).

---

## 1. Context — what we are actually building

A **self-hosted autonomy pipeline for one operator (Colin), on private repos, with the
operator nearby to fix things, and high trust in the agent.** Every design call below
falls out of that one sentence. It is *not* a hardened multi-tenant CI product, and
pretending it is has been the source of most of the accidental complexity.

Ground truth (verified 2026-07-15):

- `SuxOS/.github`, `sux`, `suxrouter`, `sux-fileops` are all **private**. There is **no
  anonymous fork-PR attacker surface.** The only actors who can open a PR or file an issue
  are the operator, the org bot (`suxbot[bot]`), and anyone explicitly granted access.
- The prior design docs repeatedly assume a **public** repo ("a repo this org runs
  PUBLIC", "the public-safety gate, revisit at go-public"). That assumption is false today
  and drives defenses against a threat that does not exist. Those defenses are removed here
  and re-earned at go-public, not before.
- The operator is **nearby and willing to intervene** — rotate a secret, revert a merge,
  unstick a queue. So the correct default is *ship and be ready to roll back*, not *block
  and wait for certainty*.

### The one real residual risk

With no fork attacker, the remaining risk is **not** "who authored this PR." It is
**prompt injection via content the agent reads** — an issue body, a scraped page, a
dependency changelog steering an autonomous agent into an action the operator wouldn't
want. Author-identity trust tiers (`OWNER|MEMBER|COLLABORATOR`, `author_association`) do
**nothing** against this: the injected instruction rides in on content, not on the
author. The only defense that works is **scoping what an agent can *do* after it reads
untrusted text** — which this repo already does well via the Safe Outputs pattern
(§2.3). So we keep that and delete the author-trust theater.

---

## 2. Security model — two tiers, and that's the whole taxonomy

Replace every ad-hoc gate (confidence tiers, high-blast classification, safe-type-title
matching, author-association trust, fork checks) with **two tiers and one label.**

### 2.1 Tier A — hard block, no override, no LLM in the loop

Deterministic. An agent physically cannot do these; they need the operator's own hands.
These are the things that are **expensive or impossible to roll back**:

- **Irreversible/destructive writes:** force-push to `main`, branch/tag deletion, repo
  deletion, history rewrite, `git reset --hard` on shared refs, dropping/truncating prod
  data stores.
- **Persistent secret exposure:** a secret committed to git history, posted into a PR/issue
  comment, or written into committed logs — anywhere it *survives* and is *indexed*.
  (A secret visible in an ephemeral CI log for a few seconds is **not** Tier A — see 2.2.)
- **PHI/PII egress:** any personal/health data leaving the trust boundary. This pipeline
  handles none today; the rule exists now so it's already in place the day it does.

Tier A is enforced by *mechanism* (branch protection, restricted tokens, Safe Outputs),
never by asking an LLM to please not.

### 2.2 Tier B — advisory, ship-and-roll-back (the default for everything else)

Red CI, a missing/unreadable review verdict, a "high-blast" diff, an unverified issue, a
stale branch, a secret briefly visible in an ephemeral log, a feature that might be wrong.
**None of these block.** They ship, they're watched, and if one turns out wrong the
response is *revert the merge / rotate the secret / fix forward* — not *gate the merge on
certainty*. The operator explicitly prefers "push something that was blocked so I can
debug it and move forward, catch the error, roll back, rotate later" over "no progress."

The last audit round already moved the no-verdict security gate into Tier B (advisory
pass, never `hold`). This model generalizes that move to the whole pipeline.

### 2.3 The one label — `hold`

`hold` is the single manual + automatic write-gate. It means "no automation touches this
PR." It is applied by exactly two things:

1. A **CONFIRMED** critical/high finding from a security review that *actually completed*
   (real signal from a finished review — not a reliability fallback).
2. The **operator**, by hand, to park anything for any reason.

Everything `hold` used to share the stage with — `feature`, `chore-safe`, `automerge`,
`confidence:*`, safe-type-title predicates — stops being an *eligibility gate*. Labels may
still exist as **descriptive** metadata, but the merge decision reads only: **green +
not-`hold` + not-draft.**

For diagnosing a pipeline that looks stuck — which loop, which workflow, which `gh` commands
to run before reaching for `hold` — see [`docs/runbooks/pipeline-wedged.md`](../runbooks/pipeline-wedged.md).

---

## 3. The three loops

The pipeline is three continuous, independent loops. Each runs on a batched cron (not
per-event — per-event fan-out is what caused the 77-parallel-Opus-sessions incident,
SuxOS/.github#140), each **always makes progress or cleanly no-ops**, none **waits** for a
quorum.

```
   ┌─────────────────────────────────────────────────────────────┐
   │  LOOP 1  collate & build   (propose → verify → cluster → PR)  │
   │  every tick: build the best available cluster, ≥1, never wait │
   └───────────────────────────────┬─────────────────────────────┘
                                    │ opens PR
                                    ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  LOOP 2  green → merge     (native auto-merge, hold is gate)  │
   │  PR green + not-hold + not-draft  →  merge                    │
   └───────────────────────────────┬─────────────────────────────┘
                                    │ PR red / behind
                                    ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  LOOP 3  red → rebase      (update-branch, capped, escalate)  │
   │  behind → update-branch (cheap) ; still red → autofix (once)  │
   │  still red → needs-human                                      │
   └─────────────────────────────────────────────────────────────┘
```

### 3.1 Loop 1 — collate & build (never waits, always builds ≥1)

**Today:** `fixer` proposes issues → `triage` (Opus) assigns `confidence:high|medium|low`
→ `issue-build` waits for a **confidence-pure** cluster (all-high, or all-medium) before it
will build. That *wait-for-a-clean-cluster* is the "no useful work, credits gone" failure:
the builder can sit idle burning scan passes because nothing forms a pure cluster.

**Target:** every run, the builder picks the **single best available grouping and builds
it — even a cluster of one.** No purity requirement, no confidence tiers, no waiting for
enough issues to accumulate.

- **Drop the confidence taxonomy entirely.** `confidence:high|medium|low` and the purity
  rule are deleted. Triage stops being a three-way scorer.
- **Keep the cheap-propose / verify-before-build separation** (it's what stops the
  expensive builder from chasing baseless proposals) — but collapse triage's *output* to
  **binary**: `buildable` or `needs-human`. That's the only judgment that changes behavior.
- **Grouping signal becomes concrete**, borrowed in *shape* from Renovate/Dependabot's
  grouped-updates schema (named groups + match rules — established prior art, don't invent
  new vocabulary), even though the "cluster freeform issues" logic itself has no
  off-the-shelf equivalent and stays bespoke (confirmed by research — Sweep/OpenHands/Devin
  are all one-issue-one-PR). Cluster by any of:
  - **same tree/file** — issues touching overlapping paths (deterministic; `gh` + a path
    heuristic, no model needed for this signal).
  - **same concept** — same root cause / feature area (the one signal that needs a model
    read — but it's "do these belong together," a cheap grouping call, *not* "how sure am I
    this is real," which was the expensive judgment we deleted).
  - **same time** — filed in one window, likely one scan pass.
- **Always build at least one thing.** If any buildable issue exists, the run produces a
  PR. The `max-clusters` cap bounds the *top* end (spend), never forces a *minimum* wait.

Net: `fixer` (propose, cheap bulk) and `issue-build` (verify-binary + cluster + build)
survive; `triage`'s three-tier confidence machinery is deleted and its residual
buildable/needs-human check folds into the front of `issue-build` (one fewer stage, one
fewer Opus session class, one fewer label family).

#### 3.1.0 Reusable pattern: hourly-shallow + daily-deep cadence pair (2026-07-15, #204)

A proposer stage doesn't have to pick one cadence. `self-fixer-hourly.yml` calls the same
`fixer.yml` reusable as `self-fixer.yml`, at a much tighter cadence (hourly vs. daily) and a
much shallower budget (`max-turns: 12` vs. `40`) — the hourly pass only catches fresh,
cheap-to-spot signal (recent commits/PRs, obvious TODOs), it does not redundantly re-sweep
the whole repo the daily pass already covered. The two callers are separate workflow files,
which gives them separate names and therefore separate concurrency groups (`fixer.yml`'s
group key is `fixer-${{ github.workflow }}`) — the hourly pass never blocks on or races the
daily one. Both still defer to `check-throttle` like any other proposer; an hourly cadence
means the governor is consulted more often, not that it's bypassed.

This generalizes beyond `fixer`: any proposer/scanner stage can be split into a cheap
frequent caller and an expensive infrequent caller of the *same* reusable, each tuned by its
own `with:` inputs, as long as the two callers have distinct workflow names (for the
concurrency-group split) and the cheap one's budget is set low enough that it's genuinely
catching only incremental signal rather than paying full-scan cost on a tight clock.

#### 3.1.1 The builder also proposes — capture insight, don't waste it (2026-07-15)

The builder holds the deepest view of a repo anyone gets that day. Making it *only* build
throws that away: a bug it trips over out-of-scope, a feature the code is obviously asking
for, a durable lesson about how the repo works — all lost when the session ends. So the
build session has a **secondary capture step**: after it finishes and pushes, it may write
up to 3 observations (`{title, body, type, security}`, same shape fixer proposes) to a file
*outside the repo tree*; a deterministic Safe-Outputs step files them as issues, which
re-enter Loop 1. This closes the loop — the pipeline that builds work also *discovers* the
next work — without a second scanning session. It is strictly secondary (never spends gate
turns), best-effort (a missing/empty file is a green no-op), and flood-guarded (below).

This is why `fixer` is no longer the *only* proposer, but stays: `fixer` is the cheap bulk
scan that runs when there's no build to ride along on; the builder's capture is the
high-signal, zero-marginal-cost proposer that only exists while a build is already happening.

#### 3.1.2 Flood guard — backpressure on feature generation

The operator's rule is "if the bots flood with features, disable auto-feature." The
deterministic half of that is the `flood-guard` composite action: it counts the bot's open
PRs, and at/over a threshold (default 8) **feature** proposals stand down — bug/security/doc
work still flows. A deep bot-PR queue means Loops 2–3 aren't keeping up, so generating more
feature work just grows the pile; the guard applies backpressure until the queue drains.
Fail-open (a lookup failure never stalls the pipeline). The operator's manual override — fully
disabling feature proposals — remains the coarse lever on top of this fine one.

#### 3.1.3 Throughput: the governor is the ceiling, not a hardcoded cap

`max-issues` (batch size) is tuned for throughput, not spend-avoidance, because
`budget-governor.yml`'s weekly runner-minute cap is the real throttle and stands the whole
build stage down at `red` before spend runs away. In-session Task-tool subagent fan-out —
**not git worktrees**; the build job is one shared checkout on one branch — lets one builder
carry a wide batch, with the builder's own disjoint-files judgment as the collision filter.
Default raised 8 → 20 → 40 (2026-07-15, the second raise paired with a 24h/15min-cadence
drain). The turns cap (300 → 500) and build job timeout (45 → 90 min) were raised alongside
each raise — turn budget saturates before issue count does, so raising the count alone just
produces truncated, uncommitted sessions instead of bigger PRs. Superseded by §3.1.4: turns
now scale with effort points, not raw count.

#### 3.1.4 Effort-aware bundling + sensed model escalation (2026-07-15)

Two related deterministic-selection upgrades, same principle as §3.1.1: a model that's
**already running** makes the judgment once, cheaply; `select` only ever reads labels — no
new LLM call is added to the orchestrator (rule: deterministic beats LLM for
selection/routing).

**Bundling.** `fixer` and the builder's own observation-capture (§3.1.1) now also emit a
rough `effort: small|medium|large` estimate per proposal, filed as an `effort:*` label
(missing/invalid → no label, which `select` treats as medium — fail-safe, never drops the
issue). `select` packs the chosen priority tier oldest-first by points (small=1, medium=2,
large=4) against `effort-budget` (default 80), capped at `max-issues` (default 40) either
way — whichever limit is hit first stops the pack. A bundle of a few `large` issues fills
the budget as fast as many `small` ones; "always build at least one thing" still holds even
if the very first issue's points alone exceed the budget. Build-session turns scale off the
selected points total (`base-max-turns + 10×points`) instead of raw issue count — a drop-in
equivalent at the medium (2pt) default, but now reflects real estimated work for a
mixed-effort batch.

**Model escalation.** Default stays sonnet (proven, near-Opus on codegen with CI +
security-review gating every PR). Auto-escalates to opus only on a **sensed** signal — the
selected batch itself carries `security` or `effort:large` — never blindly. This supersedes
the earlier "opus is opt-in only, prove it manually first" stance: the signal reuses data
`select` was already computing for tier/points, so it costs nothing extra to check, and a
bad escalation self-heals the same way any failed build does (no commit → claims released,
retried). `model-hint` still overrides in either direction — set it explicitly to force
sonnet even when the batch would sense opus, or force opus on a batch that wouldn't.
Rationale: maximize the rate of *meaningful* work — sonnet by default keeps throughput and
cost down for the common case, opus only spends more where the batch already signals it's
worth it.

**Adaptive settings per build (2026-07-15, extended).** The orchestrator now picks the whole
runtime profile — main model, subagent model, and reasoning effort — deterministically from
the tier, in one place (operator: "choose model and settings for agent and subagent for each
build" automatically):

| Tier / signal | main model | subagent model | effort |
|---|---|---|---|
| HIGH (`security`/`priority:high`) or any `effort:large` | opus | sonnet | high |
| MED (`priority:med`) | sonnet | sonnet | medium |
| LOW (floor) | sonnet | sonnet | low |

Subagents are floored at **sonnet** — never haiku for code-writing fan-out, because a weaker
subagent's bad code costs the main session more to fix than it saves (this is the reliable
half of the "haiku-expand → opus-merge" idea; the parallel cheap work lives in in-session
subagents, not a separate job). Effort tracks the model: opus always reasons deeply, the
routine floor runs fast and shallow. Wired via `CLAUDE_CODE_SUBAGENT_MODEL` /
`CLAUDE_CODE_EFFORT_LEVEL`. `model-hint` overrides the whole profile (effort falls back to
`auto` so a manual override isn't second-guessed). Defaults recalibrated against live data:
`max-issues` 40→24, `effort-budget` 80→48 (17–19-issue batches ran comfortably in 6–15 min).

**Unattended resilience.** `CLAUDE_CODE_RETRY_WATCHDOG=1` on the build session makes it wait
out a subscription usage-limit/capacity window and retry rather than fail — the
pool-exhaustion jam, handled without a metered key. `BASH_DEFAULT_TIMEOUT_MS` /
`BASH_MAX_TIMEOUT_MS` raised so a long gate command (test/build) isn't killed mid-build.
Prompt caching is already on org-wide (`ENABLE_PROMPT_CACHING_1H`; subscription auth receives
the 1-hour TTL automatically).

Deliberately NOT built: per-issue file-overlap/parallelism prediction ("smart clustering").
That's the exact fragile pass §3.1's opening paragraph documents as already ripped out —
asked a read-only model session to judge file overlap across candidates in a few turns, it
couldn't, the run built nothing. The parallelism dimension lives at build time instead, in
the model's own Task-tool subagent fan-out judgment once it's holding the bundle (§3.1.5) —
not re-predicted ahead of time by a second, cheaper, less-informed pass.

#### 3.1.5 Builder strategy freedom, real data over defensive guessing, KISS (2026-07-15)

Operator directive: "more freedom in the builder to design build plan... we don't want
knobs for knob's sake... high throughput of useful work... KISS as always." Three moves,
each grounded in something checked rather than assumed:

**Strategy is the builder's call, not a pre-decided flag.** The `fan: parallel|serial` input
is deleted. It was the orchestrator picking an execution shape before the model had even
read the issues. The build prompt now hands the model its turn budget and wall-clock ceiling
and lets it choose: parallel Task-tool fan-out for independent issues (the common default),
serial for issues that share files or depend on each other, or a first-fast-pass +
second-careful-pass shape for a batch that mixes easy and hard issues — whichever actually
fits *this* batch. This is real freedom because it costs nothing new: the model already had
Task-tool access, only the orchestrator's forced flag is gone. Explicitly out of scope: a
staging branch where fast parallel attempts (across multiple concurrent Actions jobs) dump
into a shared branch for a heavier single-model reconciler pass to clean up. That's a real,
available design (two sequential jobs — a cheap one, then one conditional on the first
leaving work unresolved) if a single build session ever proves insufficient. It is not built
today: real throughput data (below) shows no bottleneck it would fix, and it would
reintroduce concurrent-writer conflict handling this repo does not need yet. YAGNI, not
never.

**The 90-minute timeout was a defensive guess; 30 is a measurement.** It was raised to 90
alongside the turns cap (300→500, §3.1.3) without checking actual run time. Once real batches
ran at the new cap — 17 and 19 issues, SuxOS/sux runs 29430528029/29427921788 and
SuxOS/suxrouter run 29430530912 — they completed in **6.5 to 15 minutes**. The Claude step is
API-latency-bound, not something a bigger ceiling makes faster; the one CPU-bound setup step
observed (`npm ci` + LSP install) took 11 seconds. 30 minutes is ~2x the observed worst case:
a real backstop, not routine headroom. The build prompt also now tells the model its actual
budget and instructs it to trim scope (drop the lowest-value remaining issues, they retry
later) rather than let a run approach the ceiling — "ship most of the batch solidly beats
risking all of it."

**No runner upgrade, checked not assumed.** The org is on GitHub Enterprise (larger hosted
runners are actually available), but the timing data above shows no CPU/memory bottleneck —
the bottleneck is LLM round-trip latency, which runner size does not touch. Not spending
budget on an unverified guess; revisit only if a future gates step (lint/type-check/test)
shows real CPU-bound slowness.

**Bash/jq → real JS (`actions/github-script`), the org's own already-pinned convention.**
The select step's greedy-pack was a jq `reduce` — the most complex, most escaping-prone shell
in the pipeline, and shell/jq quoting was flagged directly as a recurring source of pipeline
friction (operator feedback, 2026-07-15: "bash escaping ... really fuck us up"). Migrated
select, fixer's proposal-filing, and the builder's observation-filing to
`actions/github-script@3a2844b...#v9.0.0` — already used org-wide (`audit.yml`,
`sux/deploy.yml`, `sux/health.yml`), so this is consistency with an established pattern, not
a new dependency. Real JS gets try/catch instead of `|| true` swallowing errors, structured
JSON handling instead of jq pipelines, and `core.summary` job-summary tables for free — a
genuine observability win, not just a paradigm swap. `check-throttle` and `flood-guard` were
left as single-line jq/grep — already simple, already working, converting them would be
churn without a corresponding safety win.

### 3.2 Loop 2 — green → merge (native auto-merge, not a merge queue)

**Research said "use GitHub's native merge queue."** For a high-volume repo with PR
contention, yes. **At this scale (one operator, rarely >1 PR in flight), the merge queue's
speculative batch-testing is pure overhead** — it exists to resolve contention we don't
have. The right primitive here is plain **GitHub native auto-merge (merge-when-green)**,
which `automerge.yml` already arms. Keep it; simplify what arms it.

- **Eligibility collapses to: not-draft AND not-`hold`.** Delete the safe-type-title
  regex, the `automerge|bug|security|chore-safe` label predicate, the `author_association`
  trust tier, and every fork/untrusted-author branch. On a private solo repo these gate
  against absent actors or re-encode "is CI green," which branch protection already
  enforces as the merge condition.
- **CI green is enforced by branch-protection required checks** (`Type-check & build`,
  `security-review`, `npm audit & SBOM`) — native auto-merge already waits for exactly
  those. We don't re-check them in YAML; we let the platform do it.
- **`waitch.yml` (merge-queue watcher) becomes dead code** and is removed. `pr-watch.yml`'s
  `flag-behind` default flips consideration: without a queue, BEHIND *is* actionable (Loop
  3 rebases it), so `flag-behind: true` stays correct.
- **Revisit the merge queue only if real PR contention appears** (multiple independent PRs
  racing `main` often enough that serial rebase thrashes). That's a go-bigger decision with
  a clear trigger, not a now decision.

### 3.3 Loop 3 — red/behind → rebase → autofix → needs-human → long-lived unstick

**Corrected from the original draft of this section** (2026-07-15, on implementation):
the "explicit capped ladder" this section originally called for turned out to already
exist, once traced through. `pr-auto-update.yml`'s `update-branch` on a BEHIND PR is
deterministic and idempotent — it costs nothing to retry every tick, so it needs no cap.
`claude-autofix.yml` already caps itself at `max-attempts` bot commits (counted via
`git log <merge-base>..HEAD`) and already applies `needs-human` on exhaustion. The two
don't race, because they fire on different, non-overlapping conditions (BEHIND vs. a
failed check run) — the ladder was implicit but correct:

1. **BEHIND main → `update-branch`** (`pr-auto-update.yml`, cheap, no model, no cap needed).
2. **Failing required check → `claude-autofix.yml`**, capped at `max-attempts` (default 6)
   bot commits per branch.
3. **Cap reached → `needs-human`**, applied automatically.

**What was actually missing — and is now built as `pr-unstick.yml`** — is what happens
*after* step 3. Without it, `needs-human` was a dead end: nothing re-attempts the PR until
the operator notices (which, for a solo operator not glued to notifications, can be a
long time) or `pr-drain.yml`'s close-stale sweep closes it after 14 idle days. That gap
wastes PRs that might clear themselves for free — CI failures are sometimes flaky
(the same class of harness unreliability the no-verdict security-review fix already
treats as noise), and a merge conflict sometimes resolves itself once main moves again.

`pr-unstick.yml` is a slow (daily), patient, **bounded** periodic sweep over
`needs-human` PRs (skipping `hold`/`keep`) that, per PR, past a cooldown (default 24h)
and under a cycle cap (default 3):
- re-runs the PR's failed check runs (`gh run rerun --failed` — catches flakiness), and
- runs `update-branch` again (catches "the conflict got fixed elsewhere"),
- then removes `needs-human` so the PR re-enters the normal flow.

Critically, it **does not spend a fresh LLM autofix attempt** — that budget was already
spent and correctly exhausted by `claude-autofix.yml`. It only retries the two free/cheap
moves. If the PR is still genuinely broken, the fresh CI failure re-triggers
`claude-autofix.yml` on its own, which (correctly) sees its attempt cap already spent and
re-applies `needs-human` immediately — no special-casing needed for that case. State
(cycle count, last-attempt time) lives in a single upserted marker comment on the PR, not
a label, since a label can't carry the timestamp the cooldown check needs. Past the cycle
cap, a PR falls back to exactly today's behavior: wait for the operator, or
`pr-drain.yml`'s close-stale sweep as the final backstop.

---

## 4. Don't reinvent — what we borrow off the shelf

| Need | Off-the-shelf answer | Verdict |
|---|---|---|
| Green → merge | **GitHub native auto-merge** (already armed by `automerge.yml`) | **Reuse.** Merge queue is overkill solo; revisit at contention. |
| Behind → rebase | **`gh api .../update-branch`** (already in `pr-auto-update`) | **Reuse** + add the cap + escalation ladder. |
| Retry cap / escalate | Mergify retry-then-bisect **pattern** (not the hosted app) | **Mimic the pattern**, 2-rebase cap → autofix → human. |
| Cluster related work | Renovate/Dependabot `groupName`/`packageRules` **schema shape** | **Borrow the vocabulary** (named groups + match rules); clustering *logic* stays bespoke — no tool clusters freeform issues. |
| Required-check gate | GitHub **branch-protection required checks** | **Reuse.** Stop re-checking green in YAML; let the platform gate. |

Nothing here needs a new hosted app (Mergify/Kodiak/bors). Everything is GitHub-native
primitives + our existing YAML, which is the right dependency profile for a self-hosted
solo tool.

---

## 5. Per-workflow migration map

| Workflow | Fate | Change | Status |
|---|---|---|---|
| `fixer.yml` | **keep** | Unchanged — cheap bulk proposer, already Safe-Outputs-scoped. | — |
| `triage.yml` | **deleted** | 3-tier confidence + purity deleted; binary buildable/needs-human folded into `issue-build`'s cluster pass; standalone Opus triage session retired. | **done** |
| `issue-build.yml` | **rewritten** | Selects open buildable candidates directly (no `queued-for-build` handoff); one read-only pass judges buildability + clusters by files/concept/time; always builds ≥1; purity + confidence + the automerge/needs-review labeling all gone. | **done, verified live 2026-07-16 (§6)** |
| `fixer.yml` | **trimmed** | Dropped the `confidence:*` self-assessment from its proposal schema/prompt/filing — just types now. | **done** |
| `automerge.yml` | **simplify hard** | Eligibility → `not-draft AND not-hold`. Delete safe-type-title regex, label predicate, `author_association` tier, fork branches. | **done, verified live 2026-07-16 (§6)** |
| `pr-auto-update.yml` | **keep** | Already cheap/idempotent on BEHIND; no cap needed (see §3.3's correction). | **done (no change needed); NOT verified live — could not reach a real BEHIND state in the smoke-test repo (§6)** |
| `claude-autofix.yml` | **keep** | Already caps attempts + applies `needs-human`; the ladder was implicit but correct. | **verified live 2026-07-16 — CONFIRMED BROKEN, never fires for a PR-branch CI failure (SuxOS/.github#260, §6)** |
| `pr-unstick.yml` | **new** | Long-lived unstuck mechanism: periodic, cooldown+cycle-capped retry of free/cheap moves (rerun-failed, update-branch) on `needs-human` PRs. See §3.3. | **done, verified live 2026-07-16 (§6)** |
| `pr-drain.yml` | **trim** | Keep close-stale (now the final backstop `pr-unstick.yml` falls back to). Drop the reconcile pass's re-arm logic if `automerge`'s new simplicity makes it redundant (verify before deleting). `feature` filter already dropped. | partially done; reconcile-redundancy check still open |
| `pr-watch.yml` | **keep** | `flag-behind: true` stays correct without a queue. | — |
| `waitch.yml` | **delete** | Merge-queue watcher for a queue we're not adopting. Dead. | **done** |
| `security-review.yml` | **keep, de-fork** | No-verdict already advisory (done). Already runs on every non-draft PR regardless of author_association — no fork/untrusted-author branch to remove; it was never gated that way. | **done (verified, no change needed)** |
| `deep-audit.yml` / `org-consistency.yml` | **keep** | Nightly/weekly Opus safety net; `continue-on-error` added (done). The real compensating control now that per-PR gating is Tier B. | **done** |
| `budget-governor.yml` | **retuned** | `OPUS_WF_RE` narrowed to `deep-audit|org-consistency` (triage removed from both the opus and claude regexes). | **done** |
| `deep-audit.yml` / `org-consistency.yml` (filing) | **trimmed** | Stopped filing findings with a `confidence:*` label (the label is retired). | **done** |
| `ci.yml` `audit.yml` `health.yml` | **keep** | Required checks — the actual merge gate. Unchanged. | — |
| `pin-consistency.yml` `self-check.yml` `skill-sync.yml` `pipeline-utilization.yml` `claude.yml` | **keep** | Orthogonal to the three loops. Unchanged. | — |

**Addendum (2026-07-15):** issue #189's resolution — the self-hosted repo (`.github`
itself) now runs its own Loop 3 instance via `self-pr-auto-update.yml` /
`self-pr-watch.yml` / `self-pr-drain.yml` (commit `358feed`, PR #191) — isn't reflected
in the table above; those three self-hosted stub workflows aren't listed there.

Net across Phases 0–3: **2 deleted (`waitch`, `triage`), 1 added (`pr-unstick`), 2
simplified hard (`automerge`, `issue-build`), 4 trimmed (`fixer`, `deep-audit`,
`org-consistency`, `budget-governor`), 2 confirmed-already-correct (`pr-auto-update`,
`security-review`), the rest untouched.** 21 workflows → 20. The confidence-label family,
the high-blast classifier, the author-trust tiers, and the whole `confidence:*` /
`queued-for-build` / `triaged` / `needs-review` label vocabulary are all gone — a net
simplification (fewer files, fewer session classes, fewer labels), which was the point.

---

## 6. Migration plan — phased, reversible

Each phase is independently shippable and revertible. Land behind a caller repo's
`workflow_dispatch` smoke test before it hits `schedule` across the org (per CLAUDE.md).

- **Phase 0 — docs & threat model. ✅ done.** Landed this design; corrected the "PUBLIC"
  assumption in the older docs and in `triage.yml`/`automerge.yml` comments.
- **Phase 1 — Loop 2 simplify. ✅ done, ✅ verified live 2026-07-16.** Collapsed
  `automerge.yml` eligibility to `not-draft AND not-hold` (deleted the safe-type-title
  regex, label predicate, `author_association`/fork branches, and the now-unused
  `pr-eligibility` call in this workflow); deleted `waitch.yml` and its scaffold/README
  references. `security-review.yml` was checked and found already correct — it runs on
  every non-draft PR regardless of author, so there was no fork/author branch to strip
  there.
  **Live evidence (SuxOS/sux-fileops):** opened a green, non-draft, non-held PR
  ([#102](https://github.com/SuxOS/sux-fileops/pull/102)) — `automerge.yml` armed native
  auto-merge and it merged unattended
  ([run](https://github.com/SuxOS/sux-fileops/actions/runs/29490664999)). On a second PR
  ([#103](https://github.com/SuxOS/sux-fileops/pull/103)), added `hold` — auto-merge
  refused to arm (`autoMergeRequest: null` the whole time it was held); removed `hold` —
  it armed and merged within a minute. Eligibility is confirmed to be exactly
  `not-draft AND not-hold`, no author-trust gate. **Bug found + fixed along the way:**
  sux-fileops was missing the `hold` (and `needs-human`/`feature`/`chore-safe`/`keep`/
  `self-improve`) repo labels entirely — `security-review.yml`'s
  `gh pr edit --add-label hold` was silently failing every time (`'hold' not found`,
  swallowed by the documented `2>/dev/null || true` fail-open), so the one write-gate
  this whole design is built on (§2.3) had never actually applied to a single PR in this
  repo. Fixed by provisioning the labels per README's own "Required labels" list — not a
  workflow-code bug, a caller-repo setup gap the fail-open design makes invisible until
  someone checks for it.
- **Phase 2 — Loop 3 ladder + long-lived unstick. ✅ done, ⚠️ partially verified live,
  one step CONFIRMED BROKEN 2026-07-16.** Traced the existing `pr-auto-update.yml` →
  `claude-autofix.yml` sequence and found it was already a correct, self-bounding ladder
  (see §3.3's correction) — no changes needed there. Built the piece that was actually
  missing: `pr-unstick.yml`, a daily cooldown+cycle-capped sweep that retries
  `needs-human` PRs with free/cheap moves (rerun-failed, update-branch) before falling
  back to the operator or `pr-drain.yml`'s close-stale backstop. Wired into
  `scaffold-caller.sh` and the README.
  **`pr-unstick.yml`: verified live.** Labelled `needs-human` on
  [sux-fileops#104](https://github.com/SuxOS/sux-fileops/pull/104), manually dispatched
  the caller
  ([run](https://github.com/SuxOS/sux-fileops/actions/runs/29490560903)) — it re-ran the
  failed check, rebased the branch onto main, removed `needs-human`, and upserted a
  marker comment (`cycle=1`, timestamp) exactly as designed. **Finding:** sux-fileops's
  `pr-unstick.yml` caller stub exposes `workflow_dispatch` as a bare trigger but does
  **not** forward `cooldown-hours`/`max-cycles` as dispatch inputs — they're hardcoded in
  the `with:` block, so a tester can't shorten the 24h cooldown for a repeat-cycle test
  without editing the caller file. Not fixed in this pass (cosmetic — the one-shot test
  above didn't need it); worth adding `workflow_dispatch.inputs` that fall through to
  `with:` if someone needs to exercise cycle 2/3 live.
  **`claude-autofix.yml`: verified live, and it does NOT work.** Opened a PR
  ([sux-fileops#104](https://github.com/SuxOS/sux-fileops/pull/104)) with a real,
  trivially-fixable TypeScript error and confirmed CI completed `conclusion: failure`
  three separate times over ~10 minutes while `claude-autofix.yml` was enabled.
  `claude-autofix.yml`'s `workflow_run: workflows: ["CI"]` trigger fired **zero** times —
  not even a job-filtered "skipped" run entry. Checked its entire run history across all
  three calling repos (`sux`, `suxrouter`, `sux-fileops`): every single historical run's
  `head_branch` is `main`; it has never once fired for a PR branch, org-wide. This
  directly contradicts this section's own "already caps attempts + applies
  `needs-human`; the ladder was implicit but correct" claim — the autofix rung of the
  ladder has never actually activated anywhere it's deployed. Filed as
  [SuxOS/.github#260](https://github.com/SuxOS/.github/issues/260) with full evidence and
  a suggested fix direction (replace the cross-workflow `workflow_run` listener with
  same-workflow `workflow_call` job-chaining from each caller's `ci.yml`); not fixed here
  because a trigger-mechanism change needs its own smoke-test cycle, which this session
  didn't have runway left for.
  **`pr-auto-update.yml` (BEHIND case): could not verify live.** sux-fileops's branch
  ruleset has `strict_required_status_checks_policy: false`, so GitHub's
  `mergeStateStatus` never reports `BEHIND` in this repo regardless of how far a PR's
  base has drifted — the design's own premise for this step ("when branch protection is
  strict…", §3.2) doesn't hold for the chosen smoke-test repo. Advancing `main` further
  (e.g. a direct push, as originally suggested for this test) wouldn't have produced a
  `BEHIND` state either, and would have violated sux-fileops's own CLAUDE.md ("never
  commit to `main`"), so it was skipped rather than forced. Indirect partial evidence:
  `pr-unstick.yml`'s `gh pr update-branch` call above did report "PR branch updated" for
  #104 after two unrelated merges landed on main, i.e. the literal `update-branch` git
  operation works — just not exercised via the strict-BEHIND code path `pr-auto-update`
  targets. Needs a caller repo with a strict ruleset to verify that path specifically.
- **Phase 3 — Loop 1 collapse. ✅ done, ✅ verified live end-to-end 2026-07-16.** Deleted
  `triage.yml` and the entire `confidence:*` taxonomy (dead once auto-merge stopped
  reading labels in Phase 1). Rewrote `issue-build.yml` to select open buildable
  candidates directly, judge buildability + cluster in one read-only pass (deterministic
  apply preserves Safe Outputs), and always build ≥1 — no purity gate, no waiting.
  Stripped confidence from `fixer.yml`, `deep-audit.yml`, and `org-consistency.yml`'s
  filing; retuned `budget-governor.yml`'s model regexes (Opus now only in the deep
  passes).
  **Live evidence (SuxOS/sux-fileops):** filed two small, real, unrelated issues
  ([#105](https://github.com/SuxOS/sux-fileops/issues/105),
  [#106](https://github.com/SuxOS/sux-fileops/issues/106)), manually dispatched
  `issue-build.yml`
  ([run](https://github.com/SuxOS/sux-fileops/actions/runs/29490280180)). The `select`
  step's own log: `selected tier=low count=2 points=4/6 sensedOpus=false issues=[105,106]`
  — both issues picked up with no confidence/purity gate, correctly tiered `low`
  (neither is `priority:high`/`security`), packed by `effort:*` points against the
  budget, sonnet model (no sensed-opus escalation). The `build` job opened one PR closing
  both issues ([#107](https://github.com/SuxOS/sux-fileops/pull/107)), which then cleared
  Loop 2 and auto-merged — the full Loop 1 → Loop 2 chain confirmed working end to end on
  live GitHub API responses. Also observed, independent of this session's own test: two
  pre-existing bot PRs ([#98](https://github.com/SuxOS/sux-fileops/pull/98),
  [#100](https://github.com/SuxOS/sux-fileops/pull/100)) from the repo's normal schedule
  runs, each batch-closing 2–3 issues, confirming this wasn't a one-off. **Bug found +
  fixed:** sux-fileops's `issue-build.yml` caller stub additionally had an
  `issues: types: [labeled]` trigger wired up, contradicting the reusable's own header
  comment ("batched schedule + manual dispatch — NOT an `issues:` trigger; per-event
  fan-out caused the 77-parallel-session incident, #140"). Confirmed via run history this
  had actually fired real unscheduled builds on individual labeled issues. Removed in
  [sux-fileops#103](https://github.com/SuxOS/sux-fileops/pull/103).

**Status: no longer "written but unverified."** Loop 2 (green→merge, hold gate) and Loop
1 (collate & build, always-build-≥1, no purity gate) are now verified live end-to-end,
with one real bug found and fixed in each (a caller-repo label-provisioning gap, and a
stray per-event trigger). Loop 3 is mixed: the BEHIND→rebase and stuck→unstick rungs work
(one fully verified, one structurally unreachable in the chosen test repo but indirectly
evidenced); **the red→autofix rung (`claude-autofix.yml`) is confirmed non-functional
everywhere it's deployed** (SuxOS/.github#260) — this is the one load-bearing gap left
before Loop 3 can be called done. Evidence trail: SuxOS/sux-fileops PRs #102, #103, #104,
#107; issues #105, #106; SuxOS/.github#260. The verification session found the pipeline's
automation workflows already disabled in sux-fileops when it started (likely a concurrent,
unrelated deprecation/absorption effort on that repo — a `docs/deprecation-notice`
worktree appeared there mid-session) and temporarily re-enabled exactly the five workflows
needed for these tests, restoring the original disabled state afterward; this doc's
verification therefore reflects a point-in-time smoke test, not an assertion that the
pipeline is currently live-armed in that repo. The nightly `deep-audit` + weekly
`org-consistency` Opus passes remain the compensating control if a per-PR gate misses
something.

Rollback for any phase: `git revert` the phase's PR. Because callers pin
`uses: …@main`, a revert propagates to every caller on the next run — same blast radius
that makes this repo powerful makes the undo complete.

**Addendum (2026-07-15):** issue #189 (self-hosted repo needed its own Loop 3 rebase/
watch/drain backstop — see README § Self-hosted) was resolved after this phase log was
written, via `self-pr-auto-update.yml` / `self-pr-watch.yml` / `self-pr-drain.yml`
(commit `358feed`, PR #191). Not captured as its own phase above.

---

## 7. Calibration knobs & open questions

- **Rebase cap (2)** and **autofix attempts (`max-attempts: 6`)** — starting values; tune
  from how often a rebase actually clears red vs masks a real break.
- **Binary buildability** — does folding triage's verify into `issue-build` lose enough
  cheap-verify-before-expensive-build savings to matter? Measure Opus spend before/after
  Phase 3; if the builder wastes turns on baseless proposals, restore a *thin* pre-verify
  step (still binary, never three-tier).
- **Merge queue** — the explicit go-bigger trigger is sustained PR contention. Until then,
  native auto-merge. Documented here so it's a decision, not a drift.
- **Concept-clustering model call** — the one remaining place Loop 1 needs an LLM for
  grouping; keep it cheap (bulk tier), and if grouping quality is fine deterministically
  (tree/file/time only), drop even that.

## 8. Levers considered and declined — with re-trigger conditions

The north star: **saturate ~80% of a Max-20x subscription with *useful* work — always
merging features and minor fixes, PR-ing majors — without spamming `main`, blowing load,
jamming, hanging, or being forgotten.** Every lever below was weighed against that, and
specifically against the failure this pipeline already learned once: the retired "clustering"
pass, where a separate cheap session was asked to produce an artifact a downstream session
depended on, couldn't in its turn budget, and the run built nothing. **Any "smart" addition
must be truly reliable and deterministic-ish, or it's that mistake again.** These are logged
so they're settled decisions with explicit re-open triggers, not ideas that get re-litigated
every few weeks.

| Lever | Call | Why | Re-trigger |
|---|---|---|---|
| **Anthropic prompt caching** | **Already on** | `ENABLE_PROMPT_CACHING_1H` is set on all Claude steps org-wide. The 1h TTL is well-matched to a 15-min build cadence — back-to-back runs reuse the cached prefix. | — (verify it stays set; `pin-consistency`-style check could assert it) |
| **GitHub Actions npm cache on the builder** | **Minor, optional** | The build job's LSP setup (`npm ci` + global install) is ~11s and uncached, while `audit.yml`/`health.yml` already cache npm. The win is small *speed* but real *reliability* (a registry blip on `npm ci` fails the whole build). Worth doing only because it reuses an existing pattern. | Do it if npm-registry flakiness ever fails a build; otherwise not urgent. |
| **Separate planner → builder (opus plans, sonnet builds)** | **Declined for now** | Appealing (opus decomposes better; sonnet executes cheaper), but a separate planner *job* has the exact clustering failure surface: a planning session that ends without a usable plan artifact = builder has nothing to consume = wasted cycle, plus a job boundary + artifact passing + 2× latency. The current builder already plans-then-builds **in one session** with full context, and sensed-opus-escalation already runs opus on the hard/security batches. | Build it only if we measure that opus builds are expensive **and** it's their *planning*, not their coding, that needs opus — then a cheap opus-plan → sonnet-build split earns its complexity. Do it as two sequential jobs (plan artifact → build), never as N speculative parallel plans. |
| **N×M parallelism — M builders per repo** | **Declined** | Splitting N issues across M concurrent builder jobs requires partitioning into non-conflicting slices (the clustering trap), produces M concurrent PRs (spams `main`, merge contention), and runs M concurrent sessions (blows load — the 77-parallel-Opus incident, #140). The current shape is strictly better for our constraints: **one** session per repo shares context across issues (a stated preference), fans out to **in-session Task subagents** for the safe parallelism, and emits **one** PR / **one** squashed commit with no cross-slice conflict. Cross-repo we already get M = (number of repos) genuine parallelism. | The "more parallelism" knob, if ever needed, is subagent fan-out *width inside the session* (already the model's call, §3.1.5) — not more jobs. |
| **Long-lived builder agent** | **Declined** | GitHub-hosted runners are ephemeral, which is a *feature*: every run has a hard timeout and dies clean, so the pipeline **can't hang** — directly serving the "no jamming/hanging" goal. A persistent agent trades that best-in-class reliability property for warm-context latency savings that **prompt caching already delivers** (1h TTL across the cadence). | Only if we move to self-hosted runners for some *other* reason and cold-start latency becomes the measured bottleneck. |
| **Local models** | **Declined (no substrate)** | Hosted runners have no GPU; a local model cold-loads every ephemeral run. The subscription Claude *is* the model and everything is built on it. The genuinely deterministic-ish sub-tasks (effort estimate, dedup) are already label/heuristic-based, not model calls, so even a warm local model would offload little. | Only if a self-hosted GPU runner exists for other reasons — and even then, measure whether any real model call is worth moving. |
| **Nix for CI tooling** | **Declined (non-problem)** | Could pin the LSP/tool versions reproducibly, but tool-drift isn't currently biting, and adding Nix to npm/ubuntu CI is real complexity for no current pain. | A concrete tool-version reproducibility failure. |
| **GitHub-native coding agents (copilot-swe-agent)** | **Already assessed, parked** | Only `copilot-swe-agent[bot]` supports GitHub-native issue-assignment; Claude Code has no equivalent assignable actor (fixer.yml documents the researched gap). We drive `claude-code-action` directly instead — more capable, fully in our control. | If GitHub ships an assignable Claude agent, or Copilot-agent quality clears the bar. |

**The throughline:** the reliable version of nearly every "smart" idea here is *already in
the pipeline* (in-session plan+build, in-session subagent fan-out, sensed model escalation,
ephemeral-and-can't-hang jobs, prompt caching, deterministic label-based selection). The
declined versions are the ones that move work into a **separate cheap session or job whose
output a later step depends on** — which is precisely the clustering anti-pattern. When in
doubt, keep the judgment *inside the one session that has the context*, and keep the
orchestrator deterministic.
