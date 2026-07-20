# Event-driven cross-repo dependency verification — scoping pass

> **Status:** design/scoping only — no code in this doc.
> **Trigger:** #547. Same shape of ask as #433 (multi-repo epic decomposition), #439
> (value-ranking issue selection), and #542 (budget-governor per-repo share), scoped the
> same way in `docs/design/2026-07-18-epic-decomposition-design.md`: re-derive a concrete
> plan, size it into independently-buildable slices, and commit the plan so it survives
> issue closure instead of being lost like #419/#383/#433's first attempt (see that doc's
> §4 for the failure mode this guards against).

## 1. Problem

`sux` depends on `suxlib` (`@suxos/lib`, via `file:../suxlib` — a local path dependency,
not a published npm package, so there is no registry/semver/`npm audit` signal on this
edge either). Nothing in this pipeline encodes that dependency edge or reacts to it:
`.github/managed-repos.json` is a flat `{"repos": ["sux", "suxrouter", "claude-config",
"suxlib"]}` — a list, not a graph. When `suxlib` merges a change to `main` today, `sux`
has zero automated signal until either its own next unrelated CI run happens to exercise
the changed code path, or a periodic full-org sweep (`org-consistency.yml`, an opus
judgment pass, not deterministic build/test) happens to catch it.

**This already happened.** `docs/design/2026-07-16-suxos-vx-next-arc.md` §R4: `sux`'s
durable interpreter hardcoded `faithfulUnion` in `durable.ts` while `suxlib`'s `main` had
already shipped `last-write-wins` + `field-merge` reconcile modes — a durable run of a
moded op silently degraded to faithful-union instead of erroring or using the real mode.
The vX doc's own audit trail is explicit about how this was actually caught: not by
`org-consistency.yml`'s recurring pass, but by a one-off, human-triggered "full-org
reconciliation audit" (three parallel surveys across every repo's `origin/main`, diffed
by hand against the design corpus) — i.e. the *only* thing that caught a real production
silent-degradation bug was a manual audit that doesn't run on a schedule at all. A
recurring opus judgment pass is not a substitute for this either: `org-consistency.yml`
reads code and reasons about it, but it has no mechanism that ties its cadence to *when
suxlib actually changes*, and judgment (not build/test) can plausibly read the interpreter
as fine without tracing every call site against the dependency's current shipped API.
Coincidence-or-periodic-sweep detection means the gap between a breaking `suxlib` merge
and the next chance of detection is unbounded, silent, and — per R4 — has already cost a
production incident.

The closest existing precedent is `docs/design/2026-07-16-residential-egress-contract.md`
— worth correcting one detail before building on it: #547's own issue body describes that
doc as covering "one hand-built seam (`sux`/`suxlib`)", but the doc itself is about a
different seam, `sux` ↔ `suxrouter` (the residential-egress contract), and its own "Why
not `suxlib`" section explicitly rules `suxlib` *out* as the schema's home precisely
*because* `suxrouter` has no npm dependency path to it. Docs must not lead reality
(vX-arc invariant 1, `2026-07-16-suxos-vx-next-arc.md` §6) — I'm flagging the mismatch
here rather than silently repeating it. What #547 is actually gesturing at does hold up,
though: the residential-egress doc's own "Why `.github`" reasoning —

> already the shared, org-wide home both repos' CI already trusts (every caller repo
> consumes reusable workflows from here via `uses: SuxOS/.github/...`), and it's
> fetchable by either side without a package manager

— is seam-agnostic. Nothing in that reasoning is specific to `sux`/`suxrouter`; it's a
general argument for putting any *cross-repo contract* in `.github`, which is exactly the
shape of decision this doc needs to make for the `sux`/`suxlib` seam below. So the
generalization #547 gestures at is real, just not a literal sentence in that doc — it's
the implicit shared-home argument, now being applied to a second seam.

Current state, concretely: no dependency graph anywhere in the pipeline, no event
reaction to a dependency repo's merge, and the only detection mechanism that has ever
actually worked is an unscheduled human audit.

## 2. Concrete plan

Every piece below is either an existing primitive (composite action, checkout mechanics,
throttle check) being pointed at a new use, or a genuinely new small reusable workflow —
nothing here requires new infrastructure classes.

### 2.1 Declare the graph: additive field on `managed-repos.json`

`.github/managed-repos.json` is read verbatim (`.repos` as a flat string array) by
`pin-consistency.yml`, `deep-audit.yml`, `budget-governor.yml`'s "Load managed-repo list"
step (`budget-governor.yml:115-123`, `jq -r '(.repos + [".github"]) | join(",")'`), and
`self-fabric-health.yml`'s `load-repos` job. Changing `.repos` from an array of strings to
an array of objects would break all four in one motion — exactly the caller-blast-radius
warning this repo's own `CLAUDE.md` opens with. Instead, add a **new, optional, additive
key** that none of those four ever read:

```json
{
  "_comment": "Single source of truth for the org's managed-repo list... 'dependencies' is an
    optional map of repo -> [repos it depends on and should be verified against on their
    merge to main]; omitted or absent-key means no declared dependency edges. Consumed only
    by dependency-notify.yml/dependency-verify.yml — every other consumer (pin-consistency,
    deep-audit, budget-governor, self-fabric-health) reads .repos only and is unaffected.",
  "repos": ["sux", "suxrouter", "claude-config", "suxlib"],
  "dependencies": {
    "sux": ["suxlib"]
  }
}
```

Deliberately no auto-discovery (parsing `package.json`/`file:` entries across repos this
job doesn't have checked out) — same "keep it as simple/deterministic as possible" call
the issue itself asks for, and the same shape of decision the epic-decomposition doc made
for its own schema (`epic-decomposition-design.md` §2.1: additive field, no inference).
A dispatcher needs the *reverse* edge (given "suxlib merged", who depends on it) — computed
at dispatch time by inverting the map, no separate reverse table to keep in sync:
`jq -r --arg dep suxlib '.dependencies | to_entries[] | select(.value[] == $dep) | .key' managed-repos.json`.

### 2.2 Fire the event: `repository_dispatch`, not `workflow_run`

`workflow_run` is ruled out on stronger grounds than the reliability gap this repo's own
README already documents for `claude-autofix.yml` (README.md §`workflow_run`, ~line 257):
that section's complaint was that a `workflow_run` trigger tied to a *PR-branch* CI run
structurally never fired. Here the constraint is more basic — `workflow_run` only fires
**within the same repository** as the workflow that completed; it cannot cross a repo
boundary at all, regardless of branch. Since the whole point is `suxlib`'s merge notifying
`sux`, a same-repo-only trigger is a non-starter independent of the branch issue.

`repository_dispatch` is the right primitive: it's a normal REST-API-fired event, callable
cross-repo with a scoped token — exactly the "small step in the dependency's own caller
stub, using the existing App-token pattern" #547 names. Concretely:

- New reusable workflow `dependency-notify.yml` (`workflow_call`), chained as a job inside
  a dependency repo's own `ci.yml` — the same job-chaining pattern `claude-autofix.yml`
  already established (README.md ~line 268-291), not a separate stub file, not
  `workflow_run`. Condition: `needs.<gate-job>.result == 'success' && github.ref ==
  'refs/heads/main' && github.event_name == 'push'` (only notify on an actual merge-to-main
  that passed the repo's own gates — never on a PR run).
- The job mints an App token via `mint-app-token` (`.github/actions/mint-app-token`),
  scoped with `repositories:` to exactly the dependent repos looked up by inverting §2.1's
  map for `github.repository`'s short name — the same least-privilege scoping
  `budget-governor.yml` already does for its own multi-repo sweep
  (`repositories: ${{ steps.repos.outputs.all_csv }}`).
- For each dependent, `gh api repos/SuxOS/<dependent>/dispatches -f
  event_type=dependency-merged -f client_payload[dependency]=<this-repo> -f
  client_payload[sha]=<github.sha>`.
- The dependent side needs its own event trigger, and per this repo's own
  `workflow_call`-can't-re-expose-triggers rule, that trigger lives in a caller stub, not
  the reusable: `.github/workflows/dependency-verify.yml` in `sux` declares `on:
  repository_dispatch: types: [dependency-merged]` and calls `uses:
  SuxOS/.github/.github/workflows/dependency-verify.yml@main` with `dependency:
  ${{ github.event.client_payload.dependency }}` and `sha:
  ${{ github.event.client_payload.sha }}`. (Two workflows share the name
  `dependency-verify.yml` — one the reusable in `.github`, one the caller stub in `sux` —
  matching the existing `ci.yml`/`fixer.yml` caller-stub-same-name-as-reusable convention
  already used throughout this repo.)

### 2.3 Pin at the exact just-merged commit

No registry, no tag, no publish step. `actions/checkout` the dependent repo itself under
`path: dependent` and the dependency repo at `client_payload.sha` under `path: suxlib`
(sibling `path:` values, both plain subdirectories directly under `$GITHUB_WORKSPACE` — no
workspace-escaping `../` tricks needed). Two ordinary checkout steps put
`$GITHUB_WORKSPACE/dependent` and `$GITHUB_WORKSPACE/suxlib` on disk as true siblings, and
running `npm ci` from inside `dependent/` resolves its existing, unmodified `file:../suxlib`
entry to exactly the just-checked-out pinned commit — the same on-disk layout a developer
running both repos as sibling clones already has. Then run the dependent's own gates (a
`gates-summary`-shaped input, mirroring the convention `issue-build.yml` already exposes
for this — `with: { gates-summary: "npm run type-check · npm test · npm run lint" }`) from
inside `dependent/`.

One real unknown this doc does not resolve: whether `suxlib` needs its own build step
(e.g. `npm ci && npm run build` inside the sibling checkout) before a `file:` dependent can
actually consume it, or whether `sux`'s own `npm ci` handles that transitively. This repo
doesn't have `suxlib`'s build process checked out to verify from here — slice 3 below
needs to confirm this empirically against a real `suxlib` checkout, not guess.

### 2.4 Noise control: dedupe into one refreshed issue

Reuse `upsert-tracking-issue` (`.github/actions/upsert-tracking-issue/action.yml`) exactly
as-is — no changes to that action needed. Key the dedup on a **deterministic per-edge
title with no SHA in it**, e.g. `"Dependency verify failed: suxlib → sux"`:

- On gate failure: `mode: open, update-mode: replace` — refreshes the same issue's body
  (latest failing SHA + which gate command failed + a compare link) instead of opening a
  new issue per failing merge. This is the exact "find by exact title, replace body"
  contract the action already implements for `budget-governor.yml`'s own throttle issues
  (`upsert-tracking-issue/action.yml:123-137`) — reused unmodified.
- On the next verification that passes (recovery), while an open issue for that edge still
  exists: `mode: close` — "comment-and-close it on recovery," also already implemented
  (`upsert-tracking-issue/action.yml:106-121`).
- **Not** the `tracking` label. `.github/actions/nonbuildable-labels/action.yml` fixes
  `tracking` (alongside `building,hold,needs-human,epic`) as one of the labels
  `issue-build.yml`'s own selector treats as non-buildable. A dependency-break issue is the
  opposite of bookkeeping — it's real broken-code work the normal fixer/issue-build loop
  should be able to pick up and fix like any other bug — so it must stay unlabeled-tracking
  and selectable. Use a plain, new, non-excluded label (e.g. `dependency-break`) purely so
  it's filterable/identifiable, not to hide it from the backlog.
- File the issue **in the dependent repo** (`sux`, not `.github`) — `upsert-tracking-issue`
  already supports this (`repo:` input, used exactly this way by a fixer's cross-repo
  tracking issue per that action's own doc comment) — because the fix, if there is one,
  lands in the dependent's own code, and it needs to show up in the same backlog
  `issue-build.yml` already drains for that repo.

### 2.5 Route spend through budget-governor's existing throttle

No `budget-governor.yml` changes needed — `check-throttle`
(`.github/actions/check-throttle/action.yml`) is already a generic composite that reads
any repo's own "Autonomy throttle" tracking issue (maintained org-wide by
`budget-governor.yml`'s per-repo loop, `budget-governor.yml:402-467`) and fails open. The
gate-running step in `dependency-verify.yml` (the reusable) calls `check-throttle` scoped
to the **dependent** repo (where the `npm ci` + gates spend actually happens) before doing
that work, with `defer-at: red` — the same sensitivity `issue-build.yml` uses for
backlog-draining work, not the `defer-at: yellow` the purely-speculative background sweeps
(`fixer`, `deep-audit`, `org-consistency`) use. That choice is deliberate: this feature's
entire value is catching real drift *fast* — the R4 incident's actual cost was the
multi-day gap before a human audit caught it — so deferring at yellow (a common, mild
state) would reintroduce a version of exactly the gap this closes. Deferring only at red
(truly out of budget) is the right tradeoff. (`docs/design/2026-07-20-budget-governor-
per-repo-share-design.md`, filed the same day as this doc, is scoping a *value-weighted*
refinement to the same flat per-repo throttle-issue surface — this plan is compatible with
either the current flat throttle or that future per-repo share, since it only ever reads
the `level:` line through `check-throttle`'s existing interface either way.)

## 3. The four open questions #547 names, answered

1. **How to fire cross-repo without direct event access.** §2.2: `repository_dispatch`
   from a small job chained into the dependency repo's own `ci.yml` (the established
   `claude-autofix.yml` job-chaining pattern, not a `workflow_run` stub — `workflow_run`
   cannot cross repos at all, a harder blocker than the PR-branch reliability gap already
   documented for it), using an App token from `mint-app-token` scoped via `repositories:`
   to exactly the dependents looked up from §2.1's inverted map.
2. **How to cheaply pin "install at the exact just-merged commit."** §2.3: two sibling
   `actions/checkout` steps (dependent at its own `main`, dependency at
   `client_payload.sha`) under a shared `$GITHUB_WORKSPACE` — the dependent's existing,
   unmodified `file:../suxlib` entry resolves straight to the pinned sibling checkout, no
   registry/tag/publish involved.
3. **Noise control.** §2.4: reuse `upsert-tracking-issue` unmodified, keyed by a
   deterministic per-edge title (no SHA in the title) so repeat failures refresh one issue
   (`update-mode: replace`) instead of piling up, and recovery auto-closes it
   (`mode: close`) — filed in the dependent repo, unlabeled-`tracking` so it stays
   selectable as real buildable work.
4. **Routing spend through `budget-governor.yml`'s throttle.** §2.5: the gate-running step
   calls the existing `check-throttle` composite, scoped to the dependent repo, at
   `defer-at: red` (issue-build's tier, not the more-deferrable background-sweep tier) —
   zero changes to `budget-governor.yml` itself.

## 4. Why this doc doesn't build it in one pass

Tallying the actual surfaces §2 touches: (a) a schema addition to `managed-repos.json`,
plus confirming (not modifying) that its four existing consumers are unaffected; (b) one
new reusable workflow, `dependency-notify.yml`; (c) a second new reusable workflow,
`dependency-verify.yml`; (d) caller-stub wiring in **two different repos** for two
different roles — a `ci.yml` job-chain edit in `suxlib` (dependency-notify role) and a new
`dependency-verify.yml` stub file in `sux` (dependency-verify role) — not one repo, not one
role; (e) a new tracking-issue title/label convention layered on an existing action; (f)
new `check-throttle` wiring; (g) per this repo's own `self-check.yml` gate discipline, any
new `scripts/test-*.sh` needs explicit wiring by name, and per the "Before merging a
workflow change" house rule, a change touching trigger conditions and secrets needs a real
smoke test against a live caller (`workflow_dispatch`) before it goes live on
`repository_dispatch` across the org. That is two new reusable workflows + a schema change
+ caller-stub wiring in two repos for two distinct roles + a new tracking-issue convention
+ a live smoke-test obligation — a larger surface than the epic-decomposition doc's own
four-piece tally (`epic-decomposition-design.md` §3: "new schema + cross-repo filing + a
new scheduled reconciler loop + a live DoD re-check") that doc used to justify not building
in one session, and it carries the same standing lesson that doc cites:
`three-loop-pipeline.md` §8's clustering-anti-pattern lesson — a session handed an
artifact-producing step it can't finish in its turn budget ships nothing, and anything
downstream that assumed the artifact now breaks too. Here that failure mode is sharper
because the two halves live in different repos: a half-wired `dependency-notify.yml` with
no matching `dependency-verify.yml` caller anywhere burns App-token-scoped API calls into
the void, and a half-wired `dependency-verify.yml` with no dispatcher ever configured
simply never fires — either half alone is inert or wasteful, not partially useful. The
right shape is small slices that are each independently mergeable and independently
verifiable (§5), not one cross-repo PR pair.

## 5. Suggested follow-up issues (small enough to build individually)

1. **Declare the graph.** Add the additive `dependencies` map to
   `.github/managed-repos.json` (§2.1) seeded with the one known real edge,
   `{"sux": ["suxlib"]}`, plus a doc-comment describing the field's shape and consumers.
   Confirm (grep, not edit) that `pin-consistency.yml`, `deep-audit.yml`,
   `budget-governor.yml`'s "Load managed-repo list" step, and `self-fabric-health.yml`'s
   `load-repos` job all read `.repos` only and are unaffected. Pure data + a one-line
   comment — small, no workflow logic, no dependents.
2. **Fire the event.** New reusable `dependency-notify.yml` (mint a scoped App token,
   invert §2.1's map, `gh api .../dispatches` per dependent) plus its job-chain edit into
   `suxlib`'s own `ci.yml` (the only real dependency-side producer today). Depends on
   slice 1 for the map to invert. Medium — one new reusable workflow + one caller-repo edit.
3. **Pin and verify.** New reusable `dependency-verify.yml` (sibling checkouts per §2.3,
   `npm ci`, run a `gates-summary`-shaped input) plus its caller stub
   (`on: repository_dispatch`) in `sux`. No tracking-issue or throttle wiring yet — prove
   the pin-and-run mechanism end-to-end with a plain job pass/fail as the only signal,
   and resolve the §2.3 open question about whether `suxlib` needs its own build step
   inside the sibling checkout. Can be smoke-tested via manual `workflow_dispatch` with a
   hand-supplied SHA before slice 2 is live. Medium.
4. **Wire failure/recovery + throttle.** Add the `upsert-tracking-issue` failure/recovery
   calls (§2.4: deterministic per-edge title, `update-mode: replace` on failure, `mode:
   close` on recovery, filed in the dependent repo, unlabeled-`tracking`) and the
   `check-throttle` gate (§2.5: `defer-at: red`, scoped to the dependent repo) into slice
   3's `dependency-verify.yml`. Depends on slice 3 landing first. Small-medium — additive
   steps into an already-working workflow, no new files besides the label.
5. **(Stretch, optional) Spine visibility.** Emit a `suxos_collection_ok{repo,collector=
   "dependency_verify"}`-shaped signal into `fabric-status.json` (per the collection-
   integrity contract, `CLAUDE.md`) so a silently-broken dispatcher (slice 2 failing
   without anyone noticing slice 3/4 simply never fire) is visible on the fabric-health
   dashboard instead of invisible-by-omission. Genuinely optional — slices 1-4 already
   close the actual R4 gap on their own; only worth picking up once the mechanism has run
   for real for a while and a live blind spot is actually observed, not speculatively.
