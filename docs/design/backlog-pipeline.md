# Backlog pipeline — propose → investigate → build → merge

The org-wide autonomous backlog pipeline: it turns a repo's latent work into merged
(or human-staged) PRs with little-to-no hand-holding. Reusable workflows live in
`SuxOS/.github/.github/workflows/`; each repo opts in with thin caller stubs.

## The one reframe that drives everything

`claude-code-action` runs **actual Claude Code** inside the runner. With
`CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) it authenticates as a Pro/Max
**subscription** instead of a metered `ANTHROPIC_API_KEY`. So a GitHub Actions workflow is
not an *alternative* to "a Claude agent" — it **is** a subscription-billed Claude Code
session, with GitHub providing the trigger (manual / cron / event), native fan-out (job
matrix), cloud hosting (no laptop-awake dependency), and free integration with the existing
gate/merge pipeline. That collapses the "Actions vs agents" question: it's both.

The only real cost of the subscription path is a **shared usage pool** — an autonomous run
draws from the same Pro/Max limits as interactive Claude Code / claude.ai use.

## Layers

1. **Coordination substrate — GitHub labels as a state machine.** No external DB; native,
   transparent, human-overridable.

   ```
   issue:  (untriaged) ──triage──▶ triaged + <type> + confidence:<lvl>
                                        │
                                        ├─ buildable ──▶ queued-for-build ──cluster/claim──▶ building ──build──▶ (PR opened, issue Closed on merge)
                                        └─ not buildable ──▶ needs-human (+ comment)
   PR:     confidence-pure all-high cluster ──▶ automerge  (→ merge queue)
           anything else                     ──▶ needs-review  (→ a human)
   manual overrides: `hold` blocks all automation on an issue/PR; add/remove `confidence:high` yourself to force merge/stage.
   ```

2. **Three subscription-billed Claude stages** (reusable workflows, OAuth token):
   - `fixer.yml` — **propose.** Scans a repo, files bugs + feature ideas as issues, each
     with a self-assessed `confidence:*` label. Never verifies deeply, never queues, never
     touches code.
   - `triage.yml` — **investigate.** Independently re-checks every *untriaged* issue
     (fixer's AND humans'), reading the code itself — it does not trust the filer's framing
     or confidence. Assigns its own type + confidence and, **opt-out by default, queues most
     issues** for build. Withholds `queued-for-build` only when an unattended session
     genuinely can't do it (a question, a dup, needs external info, too vague) → `needs-human`.
   - `issue-build.yml` — **collate + build.** Clusters `queued-for-build` issues
     (n issues → m PRs, never n→1; confidence-pure clusters), fans out one build session +
     PR per cluster via a job matrix.

3. **Existing gate/merge pipeline (unchanged).** Every PR the pipeline opens — even a
   `confidence:high` auto-merge — still passes **CI + security-review** (required checks)
   before the merge queue lands it. The confidence bar only decides whether a *human* also
   looks; the *machine* gates always run. That is the safety floor.

## Auth split (deliberate, do not "unify")

| Workflow | Auth | Why |
|---|---|---|
| `security-review.yml` | **`ANTHROPIC_API_KEY`** (metered) | It's a REQUIRED merge gate. On the subscription, an exhausted pool would stop it running → the merge queue jams → **nothing merges, including human PRs.** Metered API has no pool to exhaust; low volume, small cost. |
| everything else (`fixer`/`triage`/`issue-build`/`claude`/`claude-autofix`) | **`CLAUDE_CODE_OAUTH_TOKEN`** (subscription) | This is the high-volume automation — where subscription billing saves real money. A pool blip here only delays discretionary work, never jams a merge. |

Both secrets live at the **org** level so every repo inherits them via `secrets: inherit`.

## Triggers (event-driven)

Reusable workflows are `workflow_call`; triggers live in each repo's caller stub (a
`workflow_call` file can't re-expose `issues:` / `schedule:` / `workflow_run:`).

- `fixer.yml` caller — `schedule` (scan on a cadence) + `workflow_dispatch`. (Nothing
  "happens" to trigger a scan; it's time/manual.)
- `triage.yml` caller — `issues: { types: [opened, reopened] }` + `workflow_dispatch`.
  A newly-filed issue (by fixer via the App token, or a human) fires triage immediately.
- `issue-build.yml` caller — `issues: { types: [labeled] }` (gated to `queued-for-build`) +
  `workflow_dispatch`. Applying `queued-for-build` (by triage or a human) fires the build.

The full autonomous chain: **fixer files → `issues.opened` fires triage → triage queues →
`issues.labeled` fires build → PR → CI + security-review → merge queue.** Each App-token
write re-fires the next workflow (a `GITHUB_TOKEN` write would NOT — GitHub suppresses
downstream runs for it; this is why every writer mints a SUX_BOT App token first).

## Bounding cost and chaos

- **Structural caps** bound per-run spend: `fixer` max-turns; `triage` max-issues + max-turns;
  `issue-build` max-clusters + build-max-turns.
- **Cheap-exit guard.** A burst of `issues.labeled` events fires `issue-build` N times; the
  first run claims the whole queue (swaps `queued-for-build`→`building`), the rest hit a
  pre-Claude count check and exit in seconds with **zero LLM spend**. `triage` has the same
  guard (its select step gates the Claude call on count≠0). Same idea one layer up for
  `issues.opened` bursts — `triage` lists *all* untriaged each run and claims via `triaged`,
  so N events → 1 real run + N−1 fast no-ops.
- **`building`-reaper.** An issue stuck in `building` with no activity for >2h is an orphan
  from a build run that died after claiming but before opening its PR. `issue-build`'s
  cluster job re-queues such issues at the start of each run — self-healing, no separate cron.
- **`budget-guard.yml`** pauses all discretionary spenders (including these three) when the
  monthly GitHub **Actions-minutes** budget trips, via `vars.ACTIONS_BUDGET_PAUSED`. NB this
  guards *Actions minutes*, a different pool from the Claude *subscription* — the subscription
  pool is bounded only by the structural caps above and by your trigger cadence.

## Safety model

- **The machine gates are unconditional.** Confidence decides review, not whether CI /
  security-review run. A malformed or malicious auto-merge PR is still caught by them.
- **Confidence is the one LLM judgment that gates unattended merge.** It's set by `triage`
  (independent of the proposer) and re-read from the issues' *actual labels* by `issue-build`
  (never from the AI-authored PR title — that would be circular). Calibrate the triage prompt
  against reality over time; `hold` and manual `confidence:high` removal are the escape hatches.
- **PUBLIC-REPO PREREQUISITE.** Both SuxOS repos are currently **private**, so every issue
  author already has repo access — no external-injection surface. **If a repo goes public,
  add a trusted-author gate before enabling this pipeline on it:** `triage` must refuse to
  auto-queue issues from non-members (an external issue body would otherwise reach the
  code-writing build session as if it were instructions). Until then it's intentionally
  omitted rather than built as dead code.

## Interactive counterpart (skills)

The same three stages exist as cwd-based skills — `/fixer`, `/triage`, `/issue-build` — for
hands-on runs in a checked-out repo. They're the *agentic* expression of the same intent; the
workflows are the *deterministic-orchestration* expression (structured-output cluster → shell
applies labels → matrix fan-out). Two execution models on purpose: skills for driving it
yourself, workflows for unattended runs. Neither hardcodes repo paths.

## Rollout status / knobs

- Merge trust: `confidence:high` → auto-merge is **on from day one** (CI + security-review
  still gate). Dial back by having `issue-build` label high clusters `needs-review` during a
  calibration window if desired.
- A repo joins the pipeline by adding the three caller stubs + the label set
  (`queued-for-build`, `building`, `triaged`, `confidence:high|medium|low`, plus the usual
  `automerge`/`needs-review`/`needs-human`/`hold`). No central repo list to maintain.
