# Standardize CI job names org-wide → fold into org ruleset — scoping pass

> **Status:** design/scoping only — no workflow/ruleset changes in this PR.
> **Trigger:** #669, filed from an org orient sweep 2026-07-22 noting the org rulesets
> created that same day (ids 19569104 baseline + 19569106 security-review gate) still
> can't absorb per-repo CI gates because each repo's CI job name differs.

## 1. Problem, re-stated precisely

An org [ruleset](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets)
applies ONE required-status-checks list to every targeted repo. `security-review /
security-review` already works fleet-wide because `security-review.yml` is the same
reusable workflow with the same job name in every caller. Each repo's own CI/build gate
is NOT uniform:

| repo | current required CI job name |
|---|---|
| sux | `Type-check & build` (+ `audit / npm audit & SBOM`) |
| suxlib | `Test & build` |
| suxrouter | `lint` |
| claude-config | `shellcheck` |
| suxos-net | `Test & build` |
| .github | `actionlint`, `pin-consistency` |
| nix | `flake-check` |
| suxdash | `Type-check & test` |
| sux-fileops | `test` |

So today the fleet needs 7 legacy per-repo rulesets plus 2 thin shims (nix, suxdash) to
cover CI, on top of the 2 org rulesets — the opposite of the "org ruleset = single source"
goal #669 wants.

Per `2026-07-22-ci-yml-fate-decision.md` §1: this repo's own `ci.yml` reusable workflow is
NOT live-wired by any caller (`sux`/`suxrouter`/`claude-config`/`suxlib` each forked their
own CI file). That decision (Option B, "document as intentionally per-repo") is directly
relevant here — it means #669 cannot be satisfied by pointing every repo at a shared
reusable CI workflow that already exists; each repo's CI job structure is independently
maintained by design, and stays that way. What #669 actually needs is a thin, additively-
named **join job** added to each repo's own CI file — not a consolidation of the CI logic
itself.

## 2. Why this doesn't fit in one `.github`-repo PR

Two hard blockers, both structural, not effort-sizing:

1. **The changes are NOT in this repo.** Every numbered step in #669 — adding a join job,
   editing `required-gates` inputs, verifying live check-run names, deleting per-repo
   rulesets — happens in `sux`, `suxlib`, `suxrouter`, `claude-config`, `suxos-net`,
   `nix`, `suxdash`, `sux-fileops`, and the org ruleset API surface. None of it is a file
   in `SuxOS/.github`. A builder session here has nothing to commit for the actual work.
2. **This session's own `gh` token cannot reach those repos.** Per this repo's CLAUDE.md
   (confirmed live, #484/#492/#506): a builder session's default token is scoped to the
   single repo the job runs in. `gh repo view SuxOS/sux` and `gh workflow view --repo
   SuxOS/suxlib` fail with "Could not resolve to a Repository" — indistinguishable from
   the repo not existing. Editing another repo's CI workflow, checking its live check-run
   name on a real PR (#669 step 4's explicit rollout requirement), and deleting *that
   repo's* ruleset via `gh api repos/SuxOS/<r>/rulesets` are all therefore impossible from
   this session, independent of turn budget.

This is the design-doc-instead-of-drop path this repo's CLAUDE.md carves out for exactly
this shape of issue: "an issue whose own body says it needs a design/scoping pass first"
doesn't have to be dropped every cycle — a scoping doc that re-derives the plan into
independently-buildable slices is a legitimate, gate-passing build.

## 3. Concrete plan, sliced into independently-buildable pieces

Every piece below is small and self-contained; none needs the others done first except
where noted. **All of them require a human (or a builder session run inside the target
repo, with that repo's own token) to execute** — this doc is the artifact that lets that
happen without re-deriving the plan from scratch.

1. **Pick the canonical name.** Recommend `ci-gate` — short, doesn't collide with any
   existing job name in the table above, and reads clearly in a required-checks list
   next to `security-review`. This is a naming decision only; record it here so every
   later slice uses the same string instead of re-litigating it: **`ci-gate`**.

2. **Per-repo join-job additions (8 independent slices, one per repo — sux, suxlib,
   suxrouter, claude-config, suxos-net, nix, suxdash, sux-fileops).** Each slice, done
   inside that repo:
   - Add a `ci-gate` job to the repo's own CI workflow with `needs: [<all existing
     required jobs>]` and `if: always()` (so it evaluates even if a dependency was
     skipped, not just on success) that fails if any needed job's result isn't
     `success`/`skipped`. This is the standard "needs-everything join job" pattern
     #669 already names — no change to the existing per-job names or logic, they keep
     running and reporting exactly as they do today.
   - Push a throwaway PR in that repo and confirm `ci-gate` actually appears as a
     check-run name in the PR's checks list before relying on it anywhere (#669's own
     step 4 warns a required-check rename that never reports jams the merge queue
     forever — this is not optional verification, it's the step most likely to silently
     fail: e.g. a job name with a space or a matrix job needs different `needs:` handling
     than a scalar job).
   - Update that repo's own `automerge`/`pr-drain` caller stub's `required-gates` input to
     include `ci-gate` (additive — leave the existing per-job names in `required-gates`
     too, don't remove them yet; see slice 4).

3. **Add `ci-gate` to the org CI ruleset.** Once at least one repo (see rollout order
   below) has verified a live `ci-gate` check-run, add `ci-gate` to org ruleset
   `19569106` (or a new dedicated org CI ruleset, if mixing CI and security-review in one
   ruleset's required list turns out to fight this ruleset's own targeting/bypass rules —
   that's a live judgment call to make when actually looking at the ruleset UI/API, not
   something to pre-decide here). This is a single org-level change, done once, not
   per-repo — but it should NOT happen until slice 2 has verified `ci-gate` on every
   targeted repo, since the org ruleset applies to all of them simultaneously.

4. **Retire per-repo rulesets and legacy `required-gates` entries, per repo (8
   independent slices, can trail slice 3 at each repo's own pace).** Once a given repo's
   automerge has run green against the org-ruleset-required `ci-gate` for at least one
   real merge (not just a dry check), drop that repo's legacy per-job names from its
   `required-gates` input and delete that repo's own ruleset via `gh api -X DELETE
   repos/SuxOS/<r>/rulesets/<id>`.

5. **Done-check.** `gh api repos/SuxOS/<r>/rulesets` returns `[]` for all 9 repos in the
   table above (#669 lists 9; `managed-repos.json` currently tracks only 5 — `sux`,
   `suxrouter`, `claude-config`, `suxlib`, `suxdash` — plus cold-tier `suxos-net`/`nix`
   excluded by design and `.github`/`sux-fileops` not in that file at all; this doc's
   scope follows #669's own 9-repo list, not `managed-repos.json`'s, since they're
   answering different questions).

## 4. Rollout order recommendation

Start with `.github` itself (this repo) — self-check.yml already has an
`actionlint`+`pin-consistency` pair rather than one job, so it's a genuine 2-job join
case, not a trivial single-job rename, and a mistake here only blocks this repo's own
automerge, not a product repo's. Then `suxdash` or `nix` (both already carry a "thin
shim" per-repo ruleset per #669's own framing, implying they're closer to the org
default already). Leave `sux` for last — it has the most callers depending on its CI
gate staying green (`audit / npm audit & SBOM` is a second required job there, and
`sux` is the one repo `managed-repos.json` marks as a dependency target for `suxlib`),
so any rollout mistake there has the widest blast radius.

## 5. What this PR does NOT do

No workflow, ruleset, or `required-gates` value changes anywhere — this doc is scoping
only, per the constraint in §2 that none of the actual work is reachable from this
session or this repo. Follow-up issues should be filed per-slice (ideally one issue per
repo for slice 2, referencing this doc) rather than re-opening #669 as one monolithic
issue a third time.
