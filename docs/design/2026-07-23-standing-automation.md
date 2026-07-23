# Standing automation: the four words (drummer retirement)

> **Status:** ADOPTED 2026-07-23 (owner-approved, executed same day).
> **Supersedes:** the "drummer" mechanism (`/drummer` skill, `drummer-*` scheduled
> tasks, and the per-arc `drummer-v{N}-*` release-cadence pattern) everywhere it
> appears — including forward references in `2026-07-suxos-v5-arc.md`.

## Why drummer died

The owner's verdict — "I don't even understand or remember what it was or is doing" —
names the root defect: **illegibility**. A metaphor-named mechanism whose state lived
partly in a task registry and partly in prose notes could not answer "what is running
and why" without archaeology. Six concrete failure modes, all real incidents:

| # | Failure | Incident |
|---|---|---|
| F1 | Arm-state had two sources of truth (registry + prose) | stale "re-arm at wrap" note re-armed two FINISHED drummers, 2026-07-22 ~22:30Z |
| F2 | Self-disarm was the LLM's job to remember | `v1-0-cut-audit` wrote its final report, forgot to disable |
| F3 | Cron-polled gates that could be events | 30-min wakes to ask "is 1.0 published yet?" |
| F4 | Premise/TTL never encoded | `bughunt`'s "while Colin is away" expired silently; kept running |
| F5 | Name failed recall | the owner had to ask what his own mechanism was |
| F6 | Output channel drifted under it | mychart status PRs rotted when vault went PR-required |

Design selected by a 4-design adversarial panel (control-loop, abolitionist,
minimal-repair, human-interface lenses; 3 judge axes). Winner: the abolitionist
skeleton — **kill the category** — with grafts.

## The doctrine

**Standing automation is one of exactly four plain words. Nothing gets a schedule
without an end.**

| Word | What | End | Substrate |
|---|---|---|---|
| **routine** | cadence, no goal (briefs, journal) | open-ended; only the owner creates | local scheduled task |
| **timer** | fires once | its moment (`fireAt`) | local scheduled task |
| **watch** | polls ONE unpushable external condition, pings on trip | trip or mandatory expiry date | local scheduled task + `check.sh` |
| **milestone** | dev goal | GitHub close-at-merge | this pipeline (issues → loops) |

Rules, all "impossible by construction, not discipline":

1. **Registry is truth.** Armed = present in the executing substrate's own registry
   (scheduled-task list; GitHub milestone state). Prose (memory notes, vault, docs)
   may describe, never arm. No re-arm instruction may live in a note.
2. **A watch's brain is a deterministic script** (`check.sh`): expiry check first
   branch, probe, dedup stamps written by the script, verdict lines. The LLM run is a
   courier that only relays notifications and executes the script's DISARM verdict.
   Worst-case failure is a repeated visible "expired" ping — never silent overrun.
3. **Events over polls.** Release-gated work (the old `drummer-v{N}` pattern) is
   seeded by `release:published` / merge-event Actions into milestones — zero wakes.
   Polling is legal only against genuinely unpushable external state (an Epic portal
   door), at a cadence matched to the state's real change rate.
4. **Refusal rule.** A goal whose stop condition isn't a deterministic check is not a
   watch — it is pipeline work (dispatch), a milestone, or the owner's own judgment.
   The `/watch` skill refuses and routes.
5. **Heartbeat.** Every `check.sh` pass stamps `state/last-run`; external staleness
   surfacing rides the existing sux KV heartbeat / `gatherHealth` path (issue filed)
   so "watch died" is distinguishable from "nothing happened yet".

## Per-arc release cadence (replaces `drummer-v{N}-*`)

- **Implement:** arc-doc merge event seeds the arc milestone's issues (or a dispatch
  session does); the three loops drain them. No shepherd loop.
- **Cut-audit:** milestone-100%-closed surfaces via the fabric-health tick; the audit
  itself is a pipeline workflow run, reporting GREEN/AMBER to the owner. The cut
  button stays human.

## Migration record (2026-07-23)

- `drummer-mychart-doors`: mission completed at migration time — all three Epic doors
  (swedish, bozeman, evergreen) verified OPEN by direct probe; owner pinged; task
  deleted; vault status channel retired (#3 merged, #1/#2 closed).
- `drummer-bughunt`, `drummer-v1-0-cut-audit`, `drummer-v1-1-drive`: deleted from the
  registry; these + 12 corpse task dirs archived to
  `~/.claude/scheduled-tasks/.retired-2026-07-23.tar.gz`.
- `/drummer` skill replaced by `/watch` (`~/.claude/skills/watch/SKILL.md` — carries
  the taxonomy table and the courier/`check.sh` contract).
- Registry after: 3 routines, 1 timer, 1 manual task, 0 watches.

## Documented upgrade path (not built)

If standing goals ever exceed ~8–10 and the milestone/watch split chafes: one
`goals.json` registry + a single cloud supervisor (bot-authored auto-merge PR lane for
state transitions, single writer, sensor history in issue comments). The panel scored
it second; today's population does not justify the engine. Watch `check.sh` assets
migrate into it as sensors if that day comes.
