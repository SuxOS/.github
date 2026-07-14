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
     genuinely can't do it (a question, a dup, needs credentials/a human decision, too vague)
     → `needs-human`. **Research where needed:** when a call genuinely hinges on an external
     fact the code can't settle (upstream API behavior, a known bug/CVE, what a spec mandates),
     it does a focused web lookup and records the finding + source on the issue (`research_note`)
     so it's auditable and the build stage inherits it — but only where needed, not per-issue.
     Research often *un*-blocks an issue that would otherwise be `needs-human`.
   - `issue-build.yml` — **collate + build.** Clusters `queued-for-build` issues
     (n issues → m PRs, never n→1; confidence-pure clusters), fans out one build session +
     PR per cluster via a job matrix.

3. **Existing gate/merge pipeline (unchanged).** Every PR the pipeline opens — even a
   `confidence:high` auto-merge — still passes **CI + security-review** (required checks)
   before the merge queue lands it. The confidence bar only decides whether a *human* also
   looks; the *machine* gates always run. That is the safety floor.

## Auth: unified on the subscription token (2026-07, formerly split)

All Claude workflows — `fixer`/`triage`/`issue-build`/`claude`/`claude-autofix`/
`security-review` — now authenticate with **`CLAUDE_CODE_OAUTH_TOKEN`** (subscription).

`security-review.yml` was previously held on a metered `ANTHROPIC_API_KEY` on purpose: it's
a **required merge gate**, and on the subscription an exhausted pool would stop it running →
the merge queue jams → **nothing merges, including human PRs**. That risk was accepted by
explicit decision in order to consolidate on one token and stop metered spend. If merge-queue
jams from pool exhaustion become a real problem, revert `security-review.yml`'s
`claude_code_oauth_token` input back to `anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}`
and restore the `ANTHROPIC_API_KEY` org secret.

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

## Model per stage (right-sized by stakes)

Model choice follows one rule: **opus where the output is high-stakes or takes effect
unreviewed; sonnet where it's gated, bulk, or advisory** (matches the repo CLAUDE.md doctrine —
opus for codegen / adversarial review, sonnet for mechanical fan-out). All are `model` inputs,
so any caller can override.

| Stage | Model | Why |
|---|---|---|
| `triage` | **opus** | Its `confidence:high` call is what lets a build merge with NO human review — the most consequential judgment in the pipeline. |
| `issue-build` / build | **opus** | Codegen that auto-merges for a high-confidence cluster. CI + security-review still gate it, but a stronger model avoids subtle-wrong-yet-passing code. |
| `issue-build` / cluster | sonnet | Mechanical grouping. |
| `fixer` | sonnet | Bulk scan; every proposal is re-verified by triage downstream. |
| `security-review` | opus | Gates merge on its findings. |
| `claude` review / `claude-autofix` | sonnet | Advisory (a human decides) / CI-gated + attempt-capped (deliberately cheap). |

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
- **No Actions-minutes budget guard.** The org-wide `budget-guard.yml`/`ACTIONS_BUDGET_PAUSED`
  gate was retired; the structural caps above (max-issues, max-clusters, attempt caps) plus
  your trigger cadence are what bound spend now — there's no separate Actions-minutes circuit
  breaker. The Claude *subscription* pool is unaffected either way (see § auth split).

## Safety model

- **The machine gates are unconditional.** Confidence decides review, not whether CI /
  security-review run. A malformed or malicious auto-merge PR is still caught by them.
- **Confidence is the one LLM judgment that gates unattended merge.** It's set by `triage`
  (independent of the proposer) and re-read from the issues' *actual labels* by `issue-build`
  (never from the AI-authored PR title — that would be circular). Calibrate the triage prompt
  against reality over time; `hold` and manual `confidence:high` removal are the escape hatches.
- **Actor gate (built in).** `triage.yml`'s job gates on `author_association ∈
  {OWNER,MEMBER,COLLABORATOR}` whenever it's triggered by an `issues` event — so an
  untrusted user can't drive the autonomous triage→build→automerge chain (or run up spend)
  by opening an issue. It lives in the *reusable* workflow, so no caller can forget it, and
  callers add a matching visible `if:` too. `workflow_dispatch`/`schedule` runs are already
  driven by someone with write access, so they pass. On today's **private** repos every
  issue author is already trusted (the gate is a no-op there); it's what makes going public
  safe. Issue title/body is only ever read by the agent as *data* via `gh issue view` —
  never interpolated into the prompt or a shell command — so it can't inject the YAML.

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
