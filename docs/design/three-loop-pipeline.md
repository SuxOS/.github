# Three-loop pipeline — design

Status: **Phases 0–3 shipped (2026-07-15) — not yet exercised live (see §6).**
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
each raise — turn budget saturates before issue count does (`base-max-turns + 20×count`), so
raising the count alone just produces truncated, uncommitted sessions instead of bigger PRs.

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
| `issue-build.yml` | **rewritten** | Selects open buildable candidates directly (no `queued-for-build` handoff); one read-only pass judges buildability + clusters by files/concept/time; always builds ≥1; purity + confidence + the automerge/needs-review labeling all gone. | **done** |
| `fixer.yml` | **trimmed** | Dropped the `confidence:*` self-assessment from its proposal schema/prompt/filing — just types now. | **done** |
| `automerge.yml` | **simplify hard** | Eligibility → `not-draft AND not-hold`. Delete safe-type-title regex, label predicate, `author_association` tier, fork branches. | **done** |
| `pr-auto-update.yml` | **keep** | Already cheap/idempotent on BEHIND; no cap needed (see §3.3's correction). | **done (no change needed)** |
| `claude-autofix.yml` | **keep** | Already caps attempts + applies `needs-human`; the ladder was implicit but correct. | **done (no change needed)** |
| `pr-unstick.yml` | **new** | Long-lived unstuck mechanism: periodic, cooldown+cycle-capped retry of free/cheap moves (rerun-failed, update-branch) on `needs-human` PRs. See §3.3. | **done** |
| `pr-drain.yml` | **trim** | Keep close-stale (now the final backstop `pr-unstick.yml` falls back to). Drop the reconcile pass's re-arm logic if `automerge`'s new simplicity makes it redundant (verify before deleting). `feature` filter already dropped. | partially done; reconcile-redundancy check still open |
| `pr-watch.yml` | **keep** | `flag-behind: true` stays correct without a queue. | — |
| `waitch.yml` | **delete** | Merge-queue watcher for a queue we're not adopting. Dead. | **done** |
| `security-review.yml` | **keep, de-fork** | No-verdict already advisory (done). Already runs on every non-draft PR regardless of author_association — no fork/untrusted-author branch to remove; it was never gated that way. | **done (verified, no change needed)** |
| `deep-audit.yml` / `org-consistency.yml` | **keep** | Nightly/weekly Opus safety net; `continue-on-error` added (done). The real compensating control now that per-PR gating is Tier B. | **done** |
| `budget-governor.yml` | **retuned** | `OPUS_WF_RE` narrowed to `deep-audit|org-consistency` (triage removed from both the opus and claude regexes). | **done** |
| `deep-audit.yml` / `org-consistency.yml` (filing) | **trimmed** | Stopped filing findings with a `confidence:*` label (the label is retired). | **done** |
| `ci.yml` `audit.yml` `health.yml` | **keep** | Required checks — the actual merge gate. Unchanged. | — |
| `pin-consistency.yml` `self-check.yml` `skill-sync.yml` `pipeline-utilization.yml` `claude.yml` | **keep** | Orthogonal to the three loops. Unchanged. | — |

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
- **Phase 1 — Loop 2 simplify. ✅ done.** Collapsed `automerge.yml` eligibility to
  `not-draft AND not-hold` (deleted the safe-type-title regex, label predicate,
  `author_association`/fork branches, and the now-unused `pr-eligibility` call in this
  workflow); deleted `waitch.yml` and its scaffold/README references.
  `security-review.yml` was checked and found already correct — it runs on every
  non-draft PR regardless of author, so there was no fork/author branch to strip there.
  **Not yet verified live** (needs a real green/held PR in a caller repo — see below).
- **Phase 2 — Loop 3 ladder + long-lived unstick. ✅ done.** Traced the existing
  `pr-auto-update.yml` → `claude-autofix.yml` sequence and found it was already a correct,
  self-bounding ladder (see §3.3's correction) — no changes needed there. Built the piece
  that was actually missing: `pr-unstick.yml`, a daily cooldown+cycle-capped sweep that
  retries `needs-human` PRs with free/cheap moves (rerun-failed, update-branch) before
  falling back to the operator or `pr-drain.yml`'s close-stale backstop. Wired into
  `scaffold-caller.sh` and the README. **Not yet verified live.**
- **Phase 3 — Loop 1 collapse. ✅ done.** Deleted `triage.yml` and the entire
  `confidence:*` taxonomy (dead once auto-merge stopped reading labels in Phase 1). Rewrote
  `issue-build.yml` to select open buildable candidates directly, judge buildability +
  cluster in one read-only pass (deterministic apply preserves Safe Outputs), and always
  build ≥1 — no purity gate, no waiting. Stripped confidence from `fixer.yml`,
  `deep-audit.yml`, and `org-consistency.yml`'s filing; retuned `budget-governor.yml`'s
  model regexes (Opus now only in the deep passes). **Not yet exercised live.**

**Before this is truly "shipped," not just "written":** actionlint + YAML-parse pass on
every touched/new file and the invariants test is green, but none of Phases 1–3 have been
exercised against a real PR/issue in a caller repo yet — no green PR to confirm auto-merge
still arms, no held PR to confirm it doesn't, no `needs-human` PR to confirm
`pr-unstick.yml`'s marker upsert behaves, and no real backlog to confirm the rewritten
`issue-build` selects/clusters/claims correctly against live GitHub API responses (label
races, the reaper, the candidate query). Per this repo's own CLAUDE.md: land behind a
caller's `workflow_dispatch` smoke test before these hit `schedule` org-wide. The nightly
`deep-audit` + weekly `org-consistency` Opus passes are the compensating control if a
per-PR gate misses something.

Rollback for any phase: `git revert` the phase's PR. Because callers pin
`uses: …@main`, a revert propagates to every caller on the next run — same blast radius
that makes this repo powerful makes the undo complete.

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
