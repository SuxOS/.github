# Runbook — the pipeline looks wedged

For when nothing is merging / nothing is building / nothing is being proposed, and it's not
obvious why. This is the solo-operator break-glass doc `three-loop-pipeline.md` §2.3 and
CLAUDE.md assume exists — `hold` is the stop lever, this is how you find out what to point
it at (or that a `hold` isn't even the issue).

## 0. First, name which loop is actually stuck

The three loops (README § "The three loops → workflows") fail independently — knowing which
one is quiet narrows the search a lot:

| Symptom | Loop | Look at |
|---|---|---|
| No new issues/PRs appearing at all | `collate-build` | `fixer.yml` / `issue-build.yml` runs |
| Issues exist, PRs exist, but green PRs sit un-merged | `green-merge` | `automerge.yml` runs |
| PRs go red or fall behind `main` and stay that way | `red-rebase` | `pr-auto-update.yml` / `claude-autofix.yml` / `pr-unstick.yml` |

```bash
gh run list --workflow=fixer.yml -L 5
gh run list --workflow=issue-build.yml -L 5
gh run list --workflow=automerge.yml -L 5
gh run list --workflow=pr-auto-update.yml -L 5
```

Repeat with the `self-*.yml` names if this repo (`SuxOS/.github`) itself is the one that
looks stuck.

## 1. Check the governor isn't the (correct) reason nothing is running

`budget-governor.yml` throttling scheduled Claude work is not a bug — check it before
assuming one:

```bash
gh issue list --search "Autonomy throttle in:title" --state open
gh issue view <that-issue-number>   # body carries level: green|yellow|red
```

- `yellow`/`red` on the affected repo means the deferrable stages (`fixer`, `deep-audit`,
  `org-consistency`, and at `red` also `issue-build`/`triage`) are *correctly* standing down.
  This is self-healing — it clears when the trailing-7-day spend proxy drops. Don't fight it;
  if it's wrong, the fix is `opus-budget-min`/`total-budget-min` calibration
  (`budget-and-cadence.md` § Calibration), not forcing a run through it.
- A missing or unreadable throttle issue reads as green (fail-open by design) — so no issue
  found here means the governor isn't the cause, keep looking.
- `throttle-manual` label on the issue means an operator pin is in effect — check whether
  you're the one who set it and forgot.

## 2. Check for a `hold`

```bash
gh pr list --label hold --state open
gh issue list --label hold --state open
```

`hold` is the one universal stop lever (README § Required labels) — every automation
respects it. If something is `hold`ed and shouldn't be anymore, `gh pr edit <n> --remove-label
hold` (or the issue equivalent) is often the entire fix. Remember it auto-applies from a
**CONFIRMED** critical/high security-review finding, not just by hand — check the PR's review
comments before removing it blind.

## 3. Check the required-checks ruleset hasn't drifted

`automerge.yml` refuses to arm unless it can verify the default-branch ruleset actually
requires the checks it expects (`README.md` § Required secrets/vars). A ruleset edited by
hand (a required check renamed, disabled, or removed) silently stops every green PR from
merging with no error surfaced anywhere obvious:

```bash
gh api repos/{owner}/{repo}/rulesets --jq '.[] | {id, name, enforcement}'
gh api repos/{owner}/{repo}/rulesets/<id> --jq '.rules[] | select(.type=="required_status_checks")'
```

Compare the listed contexts against what CI actually posts (`Type-check & build`,
`security-review`, `npm audit & SBOM` at minimum). A renamed workflow/job is the most common
way this drifts — the ruleset still points at the old name and every PR sits green-but-
unmerged forever.

## 4. Check for stuck/self-recolliding concurrency groups

Each proposer/builder pair (e.g. `self-fixer.yml` + `self-fixer-hourly.yml`,
§3.1.0 of `three-loop-pipeline.md`) is a distinct workflow name specifically so they land in
distinct concurrency groups and never queue behind each other. If a fix ever merges two
callers under one workflow name, or a `workflow_dispatch` is fired manually into the same
group as a scheduled run, everything behind it queues invisibly:

```bash
gh run list --workflow=<name>.yml -L 10 --json status,conclusion,createdAt,headBranch
```

A long run of `queued`/`in_progress` entries with no `completed` in between is the tell.
Cancel the stuck head-of-line run (`gh run cancel <id>`) rather than waiting it out — the
30-minute build timeout / retry-watchdog (below) bounds most of these on their own, but a
truly wedged run (external API hang before the watchdog's own retry logic engages) won't
self-clear.

## 5. Check whether retry-watchdog is (correctly) waiting out a capacity window

`CLAUDE_CODE_RETRY_WATCHDOG=1` (commit 23b7987) makes an unattended Claude step wait out a
subscription usage-limit/capacity (429/529) window and retry instead of failing outright.
A run that looks "hung" in the Actions UI for an extended period may just be the watchdog
doing its job — check the step log for retry/backoff messages before killing the run. If
`security-review.yml` specifically is the one waiting and it's a merge-blocking gate, and
`ANTHROPIC_API_KEY` is set as an org/repo secret, its own break-glass third auth attempt
(`claude_apikey`) fires automatically once both subscription attempts produce no verdict —
no manual action needed if that secret already exists. If it doesn't exist and the gate is
jamming the whole queue, adding that secret is the fix (see CLAUDE.md § Auth, accepted-risk
note).

## 6. If it's still not obvious

Open a `workflow_dispatch` run of the suspect workflow by hand with the affected PR/issue
number and read the log directly — every stage in this pipeline supports manual dispatch for
exactly this reason. If the run succeeds by hand but never fires on schedule, the cron/
trigger wiring itself (caller stub, not the reusable) is the next thing to check.

## Keeping this current

This runbook is deliberately generic over "which specific incident" — the pipeline changes
fast enough that a runbook full of dated specifics goes stale before it's read twice. When a
*new* class of wedge shows up that isn't one of the checks above, add a numbered section here
rather than filing it only as a memory — that's the whole point of this file existing.
