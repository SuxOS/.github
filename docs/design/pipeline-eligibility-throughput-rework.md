# Pipeline rework — eligibility, throughput, bot-immunity, observability (2026-07)

> **Superseded (2026-07-15) by [three-loop-pipeline.md](three-loop-pipeline.md).** That
> design collapses the confidence tiers, high-blast classifier, and author-trust gates this
> doc describes into a two-tier model on the correct (PRIVATE, single-operator) threat
> assumption. This doc still assumes PUBLIC repos in places (e.g. §"Explicitly NOT changed",
> the "public-safety gate"); that assumption is **false today** — the repos are private.
> Read the three-loop design for current intent; this remains as the changelog of the
> intermediate step.

Consolidates a set of tuning changes to the org-wide backlog/merge pipeline. Read
[backlog-pipeline.md](backlog-pipeline.md) first — this doc only records what changed and why,
several of the changes deliberately reverse a rationale written into an existing code comment.

## Goal

Increase autonomous throughput ("general lubrication") without lowering the real safety floor.
The floor is: **the deterministic machine gates (CI + a *confirmed* security finding) always
apply.** Everything loosened here concerns whether a *human also looks*, or whether the pipeline's
own *reliability failures* are allowed to block work — never whether the machine gates run.

## The one principle that resolves the bot question

`suxbot[bot]` is an **autonomous LLM agent that reads attacker-controllable issue/PR text**. Two
different things can block its PRs, and they are NOT the same:

- **Mechanical blocks** — no `structured_output` emitted, OIDC blip, missing `allowed_bots`,
  no-verdict fail-closed. These are the pipeline choking on *itself*; they carry zero security
  signal. **The bot is made immune to all of these.**
- **Confirmed-finding blocks** — `security-review` actually found and confirmed a critical/high
  vuln in the diff. This is the one gate that guards autonomous-agent output, and it is *exactly*
  what an injected bot would trip. **The bot stays subject to these.**

Keying bot-immunity on "did the review confirm a finding" (not "who authored it") cleanly separates
"the harness broke" from "the diff is dangerous". This split was chosen explicitly (2026-07-14).

## Changes

### 1. Eligibility — feature label no longer vetoes; medium confidence can auto-merge

- **Feature PRs** (`automerge.yml`, `pr-drain.yml`): the blanket `feature`-label exclusion is
  removed. A `feature` PR is now eligible **iff it independently satisfies the shared core
  predicate** (`pr-eligibility` action: safe-type title or eligible label, not breaking) AND is a
  trusted author AND is not `hold`. `feature` stops being a special veto; it is no longer read at
  all by the merge paths. Rationale reversed: the old comment "feature label (needs a human)"
  assumed every feature needs review; the new posture is that a feature that *also* carries an
  `automerge`/safe-type signal is as safe as any other such PR.
- **Medium confidence** (`issue-build.yml`): a cluster earns the `automerge` label when **every**
  issue in it is `confidence:high` **OR** every issue is `confidence:medium` — still
  **confidence-pure** (never mixes tiers, preserving the existing purity rule so a high cluster's
  merge can't drag along an unverified issue). Previously only all-high clusters auto-merged.
  Medium is triage's "real/worthwhile but with scope or judgment to it" tier; letting a *pure*
  medium cluster auto-merge (still behind CI + security-review) is the intended lubrication.

### 2. Bot immunity to mechanical blocks (never a confirmed-finding exemption)

- `automerge.yml`: `suxbot[bot]` is a first-class trusted author. The old gate trusted a bot PR
  only if it carried the `self-improve` label; now an org-bot-authored PR is trusted like an
  org member (it still must pass the eligibility predicate + branch protection + all gates).
- `security-review.yml`:
  - `allowed-bots` input now **defaults to `suxbot[bot]`** (was `""`). A caller that forgets to
    pass it no longer causes the action to refuse a bot PR and hard-fail the required gate.
  - The no-verdict path is **advisory (never fail-closed) for bot PRs**, same as for a trusted
    org member — a harness hiccup on a bot PR can't apply `hold`. (App-authored PRs already carry
    a trusted `author_association`, so this was *mostly* true; the change makes it explicit and
    also covers the `user.type == 'Bot'` signal so it can't silently regress.)
  - **Unchanged:** a *confirmed* critical/high finding still applies `hold` to a bot PR. This is
    the deliberate floor from the principle above.

### 3. Throughput caps + clustering quality

- `issue-build.yml` `max-clusters`: **10 → 20**. `pr-drain.yml` `pr-limit`: **100 → 200**. Both
  are per-run *visibility* caps (truncation is logged); raising them surfaces more in-flight work
  and cannot reduce safety.
- `issue-build.yml` cluster prompt sharpened: give the model explicit relatedness signals
  (shared files / shared root cause / shared feature area) and an explicit instruction to avoid
  gratuitous singletons, to cut accidental one-issue clusters without violating confidence-purity.

### 4. Observability — DEFERRED to the generalized-framework pitch

Originally scoped here as a `pipeline-status.yml` (label-derived queue depths + oldest-item age
upserted to a tracking issue) plus a shared telemetry schema. **Deferred** to
[SuxOS/sux#452](https://github.com/SuxOS/sux/issues/452), which now owns the whole generalized work
framework — the job engine, the multi-session `claim` coordination registry, AND the telemetry
contract (`{ pipeline, stage, event: stage_entered|claimed|completed|reaped|failed, item_id, ts,
meta }`) that both the CF engine and this GitHub pipeline will emit into one Grafana. Not built in
this rework; the eligibility / throughput / bot-immunity changes above stand on their own.

## Explicitly NOT changed

- The **confirmed critical/high `hold`** on any PR, bot or human. Not weakened.
- ~~The **fail-closed hold** on high-blast, no-verdict, *untrusted*-author diffs. Kept~~ —
  **superseded**: a subsequent pass removed the high-blast/trusted-author fail-closed
  entirely. A missing/unreadable verdict is now an unconditional advisory pass, never a
  `hold`, regardless of what the diff touches — accepted tradeoff, favoring throughput
  over blocking merges on a flaky review run. See `security-review.yml`'s "Gate — advisory
  pass on missing verdict" step.
- The **author-trust tier** for auto-merge stays `OWNER|MEMBER|COLLABORATOR` (+ the org bot). Not
  widened to `CONTRIBUTOR`/`NONE` — that is the public-safety gate, revisit at go-public.

## Rollout

Shared reusable workflows → every caller inherits on merge. Land behind a caller's
`workflow_dispatch` smoke test where `if:`/eligibility logic changed (`automerge`,
`security-review`) before it goes live on `schedule`/`issues` triggers org-wide.
