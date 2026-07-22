# `ci-gate` per-repo follow-up issues — ready-to-file drafts

> Filed in response to #674, which itself follows from
> `2026-07-22-org-ci-job-name-standardization-scoping.md` (#669's scoping pass).

## Why this is a doc, not filed issues

#674 asks for one issue per repo (slice 2 of the scoping doc: add a `ci-gate` join job)
so that `issue-build.yml`'s normal per-repo loop can pick each one up. That filing has
the same structural blocker as #669 itself: this session's `gh` token is scoped to
`SuxOS/.github` only (confirmed live — `gh api repos/SuxOS/sux` returns 404 "Not
Found," indistinguishable from the repo not existing, per CLAUDE.md's #484/#492/#506
note). `managed-repos.json` also only tracks 5 of the 9 target repos (`sux`,
`suxrouter`, `claude-config`, `suxlib`, `suxdash`), so even `fixer.yml`'s existing
cross-repo epic-filing token (`mint-app-token` scoped via that file) can't reach
`suxos-net`, `nix`, or `sux-fileops` without a separate, deliberate scope decision —
not something to improvise inside this batch.

So this doc does what #669's own doc did: turns the plan into a copy-paste-ready
artifact so filing is a mechanical act (by a human, or a future session running with
the target repo's own token, or a deliberately-scoped cross-repo automation change)
instead of re-deriving titles/bodies from scratch. File each block below as one issue
in the named repo.

## Extra wrinkle found while drafting `.github`'s own entry

The scoping doc's rollout order recommends starting with `.github` itself since it's
reachable from this repo. But `.github`'s two required checks (`actionlint`,
`pin-consistency`) live in two SEPARATE workflow files (`self-check.yml`,
`pin-consistency.yml`), each with its own trigger. A `needs:` join job can only depend
on jobs within the same workflow run — it cannot join across two independently-
triggered workflow files. So `.github`'s own slice-2 draft below is scoped to figuring
out the right join mechanism (e.g. merging both jobs into one workflow, or an
external "all these check-runs succeeded" poll step) rather than a one-line `needs:`
add like the other 8 repos get. Flagging this now so whoever builds it doesn't
discover the wrinkle mid-implementation.

## Per-repo drafts (file each in the named repo)

### `SuxOS/sux`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with `needs: [<all existing
required jobs — currently "Type-check & build" and "audit / npm audit & SBOM">]` and
`if: always()`, failing if any needed job's result isn't `success`/`skipped`. Push a
throwaway PR and confirm `ci-gate` actually appears as a check-run name before relying
on it. Then update this repo's `automerge`/`pr-drain` caller stub's `required-gates`
input to add `ci-gate` (additive — keep the existing per-job names for now; a separate
follow-up retires them once the org ruleset requires `ci-gate` and this repo has run
green against it for at least one real merge). Save for last in the org rollout order —
`sux` has the widest blast radius (other repos depend on its CI staying green).

### `SuxOS/suxlib`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with `needs: [Test & build]`
and `if: always()`, failing if that job's result isn't `success`/`skipped`. Push a
throwaway PR and confirm `ci-gate` appears as a check-run name before relying on it.
Then update this repo's automerge caller stub's `required-gates` input to add
`ci-gate` additively (keep `Test & build` listed too for now — retirement is a
separate follow-up once the org ruleset requires `ci-gate`).

### `SuxOS/suxrouter`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with `needs: [lint]` and
`if: always()`, failing if `lint`'s result isn't `success`/`skipped`. Push a
throwaway PR and confirm `ci-gate` appears as a check-run name before relying on it.
Then update this repo's automerge caller stub's `required-gates` input to add
`ci-gate` additively (keep `lint` listed too for now).

### `SuxOS/claude-config`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with `needs: [shellcheck]`
and `if: always()`, failing if `shellcheck`'s result isn't `success`/`skipped`. Push a
throwaway PR and confirm `ci-gate` appears as a check-run name before relying on it.
Then update this repo's automerge caller stub's `required-gates` input to add
`ci-gate` additively (keep `shellcheck` listed too for now).

### `SuxOS/suxos-net`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with `needs: [Test & build]`
and `if: always()`, failing if that job's result isn't `success`/`skipped`. This repo
is cold-tier (excluded from `managed-repos.json` by design, minimal caller set) — check
whether it even has an automerge/pr-drain caller stub before assuming one exists to
update; if not, the `ci-gate` job addition alone still satisfies the org-ruleset
rollout precondition (slice 3 needs it verified live, not necessarily wired into a
local gate this repo doesn't otherwise use).

### `SuxOS/nix`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with `needs: [flake-check]`
and `if: always()`, failing if `flake-check`'s result isn't `success`/`skipped`. Per
the scoping doc's rollout order, this repo (like `suxdash`) already carries a "thin
shim" per-repo ruleset, implying it's closer to the org default already — a good
early rollout target after `.github`. Cold-tier like `suxos-net`: check for an
existing automerge caller stub before assuming one to update.

### `SuxOS/suxdash`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with
`needs: [Type-check & test]` and `if: always()`, failing if that job's result isn't
`success`/`skipped`. Push a throwaway PR and confirm `ci-gate` appears as a check-run
name before relying on it. Then update this repo's automerge caller stub's
`required-gates` input to add `ci-gate` additively (keep `Type-check & test` listed
too for now). Good early rollout target per the scoping doc's order (already carries
a thin-shim per-repo ruleset).

### `SuxOS/sux-fileops`
**Title:** Add `ci-gate` join job to CI workflow
**Body:**
Per `SuxOS/.github`'s `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md`
(slice 2), add a `ci-gate` job to this repo's CI workflow with `needs: [test]` and
`if: always()`, failing if `test`'s result isn't `success`/`skipped`. This repo isn't
tracked in `managed-repos.json` at all — check whether it has an automerge/pr-drain
caller stub before assuming one exists to update.

### `SuxOS/.github` (this repo)
**Title:** Design a `ci-gate` join mechanism across `self-check.yml` and `pin-consistency.yml`
**Body:**
Per `docs/design/2026-07-22-org-ci-job-name-standardization-scoping.md` (slice 2) and
`docs/design/2026-07-22-ci-gate-followup-issue-drafts.md`'s "extra wrinkle" section:
this repo's two required checks (`actionlint`, `pin-consistency`) live in two
independently-triggered workflow files, so the plain "`needs:` join job" pattern used
for the other 8 repos doesn't directly apply here. Needs a short design pass: either
merge both jobs into one workflow file (bigger diff, but a normal `needs:` join
becomes possible), or add a separate polling step that checks both check-runs'
conclusions via the Checks API before reporting `ci-gate` (more moving parts, no
workflow-file merge required). Pick one and implement slice 2 for this repo once
decided — this repo's own required-checks ruleset (`19501534`) is the one to update
afterward, additively, same pattern as every other repo's slice 2.

## Org-ruleset step (slice 3) and retirement tracking (slice 4)

Per #674's phrasing, these are tracked as two more items rather than 8 more per-repo
drafts:

**Org-ruleset step** — file in `SuxOS/.github` (it's an org-level action, not a
per-repo file change): once every repo above has verified a live `ci-gate` check-run
(slice 2 done everywhere), add `ci-gate` to org ruleset `19569106` (or a new dedicated
org CI ruleset — a live judgment call per the scoping doc, not pre-decided here).
Single change, done once, after all 9 slice-2 rollouts land.

**Retirement step** — file in `SuxOS/.github` as a tracking issue whose actual
retirement work happens per-repo (8 independent slices, same access model as slice 2
above — needs a human or a session with that repo's own token): once a repo's
automerge has run green against the org-ruleset-required `ci-gate` for at least one
real merge, drop that repo's legacy per-job names from its `required-gates` input and
delete that repo's own ruleset (`gh api -X DELETE repos/SuxOS/<r>/rulesets/<id>`).
Done-check per the scoping doc's §5: `gh api repos/SuxOS/<r>/rulesets` returns `[]`
for all 9 repos.
