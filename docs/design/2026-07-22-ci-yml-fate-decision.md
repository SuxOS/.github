# Fate of the `ci.yml` reusable workflow and its scaffold stub — decision

> **Status:** decision doc — analysis + recommendation, not a retirement in this PR.
> **Trigger:** #579, the "separately worth a decision" item #552 explicitly scoped out
> of its own reconciliation pass. #552 already reconciled scaffold-caller.sh's
> automerge/issue-build templates and label list against the converged caller shape;
> this is the one item it deliberately left for a human/design call rather than
> bundling into that same pass.

## 1. Current state

- `ci.yml` (`.github/workflows/ci.yml`) is a `workflow_call`-only reusable with
  sux-specific defaults (`wrangler-config: sux/wrangler.jsonc`, `gen-index-path:
  sux/src/fns/index.ts`, `extra-checks-scripts: check:node`).
- No live caller (`sux`, `suxrouter`, `claude-config`, `suxlib`) actually wires it —
  each forked its own `ci.yml` instead (#552's own finding).
- `scripts/scaffold-caller.sh`'s `emit ci` (lines ~81-99) still unconditionally
  generates a caller stub that calls the reusable for any freshly-scaffolded repo —
  there is no flag to skip it, unlike some of the pipeline's other opt-in emits.
- README.md documents `ci.yml` prominently as one of the four required "Gates" (§ "The
  two groups") and shows two worked examples of wiring it (§ "Reusable workflow
  reference"), reading as if it is the org's live, standard CI gate.
- `claude-autofix.yml`'s job-chaining contract (README § `workflow_run`) is written
  against "each caller's own `ci.yml`" generically — it does not require the file to
  be the reusable specifically, only that a `ci.yml` gate job exists to chain from.
  This is important: the autofix chaining pattern does NOT depend on which way this
  decision goes.

## 2. Options

**A — Retire.** Delete `.github/workflows/ci.yml`, drop `emit ci` from
`scaffold-caller.sh`, and update README to remove `ci.yml` from the reusable-workflow
list and its two worked examples.

- Pro: removes genuinely dead code and a scaffold stub that (per #552) already
  generates a caller-repo file (`ci.yml`) with a hardcoded reference to a reusable
  workflow nobody uses — a fresh repo's very first CI run would be exercising an
  unmaintained path.
  - Con: irreversible in the way this repo's own CLAUDE.md warns about for shared
  files — "a change here is a change to every caller repo's ... pipeline
  simultaneously." If any future repo's layout DOES fit the reusable's sux-shaped
  defaults closely enough to be worth adopting as-is, retiring removes that option
  outright rather than leaving it available. There is no live caller to break today,
  but there is also no live caller to consult about whether they'd have used it.
- Con: this repo's own guidance (CLAUDE.md "before merging a workflow change") is to
  test against a real caller when a change touches trigger conditions/secrets/`if:`
  logic — retirement has no real caller left to test the *absence* against, so the
  actual risk being avoided (an unused stub going stale) is low, but so is the actual
  benefit (nothing is currently broken by ci.yml existing).

**B — Document as intentionally per-repo (recommended).** Keep `ci.yml` and its
scaffold stub as an optional, explicitly-labeled starting point; stop presenting it in
README as though it's the org's live standard, and note in the file itself and the
scaffold's `emit ci` block that no current caller wires it — each repo maintains its
own CI shape instead.

- Pro: zero blast radius — no deletion of a file some future repo might genuinely want
  to adopt unmodified, no scaffold behavior change to re-verify against a live caller.
  Purely a documentation clarification, which is exactly the kind of change this
  repo's CLAUDE.md says does NOT need the "test against a real caller" discipline
  (nothing here touches trigger conditions, secrets, or `if:` logic).
- Pro: preserves the actual working part — `claude-autofix.yml`'s job-chaining
  contract already documents itself against "each caller's own `ci.yml`" generically,
  so nothing about that contract needs to change either way.
- Con: leaves a stub in `scaffold-caller.sh` that, if a future repo scaffolds with
  defaults and never overrides `wrangler-config`/`gen-index-path`, silently wires
  itself against sux-shaped assumptions that don't fit. Mitigated by making that
  explicit in the emitted stub's own comment (§3) rather than removing the behavior.

## 3. Recommendation and what this PR does

**Recommend Option B.** Retiring a reusable workflow that's still technically
functional (just unwired) is a one-way door with no live caller to lose by keeping it
and no live caller to consult about losing it — the asymmetry favors the reversible
choice. This PR:

- Adds an explicit note to `ci.yml`'s own header comment and to `scaffold-caller.sh`'s
  `emit ci` block stating no current caller (`sux`/`suxrouter`/`claude-config`/
  `suxlib`) wires this reusable — each maintains its own forked `ci.yml` — so a repo
  scaffolding fresh knows this is a starting template to adapt or replace, not a
  proven-live default to trust as-is.
- Leaves README's existing "Gates"/"Reusable workflow reference" sections unchanged in
  structure (still documents how to wire it, for the repo that does want to), since
  that documentation is accurate on its own terms (this IS how you'd wire it, if you
  wired it) — only the two files closest to a fresh-scaffold user (the workflow file
  itself, the scaffold script) get the "nobody currently does this" caveat.

If a future review finds Option A is actually preferred (e.g. `ci.yml` visibly
bit-rots against a real repo shape, or the scaffold stub causes a real incident), that
retirement is a separate, small follow-up — deleting a documented-as-optional
reusable is a strictly easier decision to revisit later than un-deleting one now.
