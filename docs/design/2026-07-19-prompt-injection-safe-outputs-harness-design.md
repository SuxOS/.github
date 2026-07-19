# Adversarial prompt-injection / Safe Outputs test harness — scoping pass

> **Status:** design/scoping only — no code in this doc.
> **Trigger:** #516. Per this repo's own established precedent (see
> `2026-07-18-epic-decomposition-design.md`, `2026-07-18-value-ranking-selection-design.md`,
> `2026-07-19-live-fire-acceptance-harness-design.md`), an `effort:large` issue asking for
> new corpus + canary wiring + an assertion harness ships this doc as its first buildable
> slice instead of being REDUCE-dropped every builder session.

## 1. Problem

`docs/design/three-loop-pipeline.md:33-42` states the entire security model's one
residual risk in plain terms: with no fork attacker on these private repos, "the
remaining risk is not who authored this PR. It is prompt injection via content the
agent reads... The only defense that works is scoping what an agent can do after it
reads untrusted text — which this repo already does well via the Safe Outputs pattern."
That claim is asserted, and the mechanism (fixer.yml/issue-build.yml/deep-audit.yml/
org-consistency.yml each restricting agent-driven mutation to one narrow, deterministic,
post-hoc-validated write path — see e.g. `issue-build.yml:1001-1035`'s observation-filing
step, which re-validates type against an allowlist and never lets the model write
anything but a JSON file the deterministic step then parses) is real and well-documented.
But nobody has ever fed one of these agents a crafted adversarial payload and checked
that the envelope actually holds. Confirmed via issue search (`gh issue list --state
all`) that no issue — open or closed — tracks "prompt injection", "adversarial", "fuzz",
or "Safe Outputs" testing; this is a genuinely untracked gap in the one place the whole
two-tier model says to look, not a duplicate of other open large issues covering
different ground (see §2).

## 2. Relationship to #490 and #483 — do not build a fourth canary

Two other open/recent issues already need a disposable, low-stakes repo to safely run
an agent against adversarial or unproven conditions:

- **#490** wants a persistent canary for `caller-conformance.yml`'s post-merge
  detect/remediate chaos-test loop.
- **#483**, scoped in `2026-07-19-live-fire-acceptance-harness-design.md`, wants a
  canary for a pre-merge live-fire acceptance test of reusable-workflow *trigger*
  mechanics (ref-indirection, `if:` conditions), and that doc's own §2 already
  proposes the two **share one provisioned repo** (`SuxOS/pipeline-canary`, its own
  least-privilege GitHub App install) rather than standing up two.

This issue's payload corpus needs the same kind of disposable target — somewhere an
agent can be handed a malicious issue body / PR comment and actually act on it without
polluting real backlog data or real repo state. That's a third consumer of the same
primitive, not a new one: whichever of #490/#483 provisions `SuxOS/pipeline-canary`
first, this harness dispatches against it too, adding its own `workflow_dispatch`-only
stubs (mirroring caller-conformance's and the live-fire target's shape) rather than
provisioning anything of its own. What #490/#483 test is *pipeline mechanics under
controlled conditions*; what this issue tests is *agent behavior under a hostile
input* — a different axis, same shared infrastructure.

## 3. Concrete plan

1. **Corpus (no canary dependency — buildable standalone).** A fixture set under
   `tests/adversarial/injection-corpus/`, one file per payload, each annotated with
   which agent loop it targets (fixer's proposer scan, issue-build's builder session,
   deep-audit's read-only reviewer, org-consistency's checker) and what a safe response
   looks like. Payload shapes worth covering, drawn directly from the threat model in
   `three-loop-pipeline.md`: an issue body instructing the agent to write outside its
   intended file set; a dependency-changelog-style string embedding a fake `hold`-removal
   or `automerge`-label instruction; a PR-comment payload attempting to make the agent
   post a secret-shaped string into a comment (exfiltration via the one channel these
   agents *can* write to); a payload mimicking this repo's own `classify-security-
   noverdict.sh` anti-spoof cases (SuxOS/.github#271-adjacent) but aimed at a builder/
   fixer session instead of the security reviewer. This is pure content + expected-
   behavior annotations — no infra, independently reviewable, and the part most worth a
   dedicated careful pass rather than being rushed alongside unrelated issues in one
   session.
2. **Assertion harness logic (buildable and testable standalone, wiring deferred).**
   The check itself — "did the agent's actual output stay inside its Safe Outputs
   envelope" — is a deterministic read over whatever the agent under test produced
   (a diff, a posted comment, a filed issue/PR): assert no file outside the caller's
   declared path set changed; assert no comment/log contains a known-secret-shaped
   canary token; assert no label mutation touched `hold`/`automerge` from an agent-
   authored step. This logic can be written and unit-tested now, fixture-driven, the
   same way `scripts/test-classify-security-noverdict.sh` drives
   `classify-security-noverdict.sh` with synthetic transcripts and no live `gh` — it
   does not need a live canary to exist first, only a live *dispatch* does.
3. **Canary wiring (blocked on #490 or #483 provisioning `SuxOS/pipeline-canary`).**
   Once either lands the shared repo, add `workflow_dispatch`-only stubs there that run
   the target loop (fixer/issue-build/deep-audit/org-consistency) against a synthetic
   issue/PR seeded from the corpus, then run the assertion harness from (2) against the
   result. `claude-autofix.yml`'s rung is excluded for now — `three-loop-pipeline.md`'s
   own status line already flags it BROKEN org-wide (#260); testing an already-known-
   broken path against adversarial input first would conflate two different failure
   classes.
4. **Cadence.** Periodic (`workflow_dispatch` + a light `schedule`, e.g. weekly), never
   a per-PR merge gate — this is adversarial-robustness testing, not correctness CI, and
   `docs/design/budget-and-cadence.md`'s per-workflow spend discipline applies the same
   way it does to `deep-audit.yml`'s nightly cadence.

## 4. Why this PR doesn't build it

Slices (1) and (2) above are genuinely independent of any canary and could each be a
small-to-medium standalone follow-up; slice (3) is explicitly blocked on #490/#483
landing a shared canary repo that doesn't exist yet, and building a second, throwaway
canary just for this issue would be exactly the duplicated-infrastructure mistake
`2026-07-19-live-fire-acceptance-harness-design.md` §2 already flags and avoids for its
own issue. Attempting all three in one session — alongside #507 and #495 in this same
batch — risks either a non-representative corpus (rushed adversarial content is worse
than none, since a thin corpus reads as "tested" when it barely covers the threat
model) or canary-wiring debt that has to be re-done once #490/#483 settle on the real
shared repo's shape. Right-sizing into independently-buildable, independently-droppable
slices (per this repo's own established precedent for `effort:large` scoping issues)
is a better outcome than a half-wired mechanism nobody can trust.

## 5. Suggested follow-up issues (small enough to build individually)

- Build the `tests/adversarial/injection-corpus/` fixture set (§3.1) — small-medium,
  no dependencies, the part most worth a dedicated careful adversarial-writing pass.
- Build and unit-test the Safe-Outputs-envelope assertion harness logic (§3.2) against
  synthetic fixture transcripts, no live canary — small-medium, no dependencies, same
  extraction-and-fixture pattern this repo's `scripts/test-*.sh` suite already uses.
- Wire both against `SuxOS/pipeline-canary` once #490 or #483 provisions it (§3.3) —
  medium, depends on both of the above and on whichever of #490/#483 lands first.
- Decide and document the corpus's target-loop coverage order once slice 3 is live
  (fixer/issue-build/deep-audit/org-consistency first; `claude-autofix.yml` only after
  #260 is fixed) — small, depends on the wiring above.
