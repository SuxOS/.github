> **DISSOLVED — not answered (2026-07-15, loci redesign).** Local and cloud are not a mode
> choice. The operator works locally in-thread (locus = cwd) while the three loops run
> continuously in the cloud regardless; `dispatch` seeds/controls the pipeline and
> `orient` monitors it — both always run. The `/develop` and `org-watch` skills and
> `tools/control-panel` referenced below no longer exist (folded into `orient`/`work`/
> `dispatch`). See `claude-config/docs/superpowers/specs/2026-07-15-loci-redesign-design.md`
> and `three-loop-pipeline.md`. Kept for history; the fork below is moot.

# Open question: what is the cloud fabric *for*?

Surfaced while rebuilding `claude-config`'s `/develop` skill to be workspace-folder-aware
(see `claude-config/WORKFLOW.md` and `home/.claude/fabric.json` on that repo). Parking here
because it's an org-autonomy-model decision, not a claude-config implementation detail —
it determines how fixer/triage/issue-build, the bot account, and `tools/control-panel` relate
to a human driving Claude in-thread.

## The fork

`/develop` (the local dev-loop skill) needs a default locus. Three options, not yet decided:

1. **Local-first.** You + Claude work clones directly, in-thread, worktree-isolated. The cloud
   fabric (fixer/triage/issue-build, `bot@colinxs.com`, `tools/control-panel`) is an occasional
   opt-in escape hatch for unattended drains across many repos. `develop` defaults local;
   cloud requires `--cloud`.
2. **Cloud-first engine.** The fabric *is* the point — it develops the org autonomously while
   you're away (bot account, GH Actions, label state machine). Local becomes the hands-on
   override for unjamming or one-off work. `develop` defaults to dispatch; `org-watch` becomes
   the monitor over what the bot did, not a peer to a local loop.
3. **Two co-equal modes, no default.** Every invocation names local or cloud explicitly. More
   friction per call, zero wrong-mode surprises.

## Why it matters beyond one skill

This also decides:
- Whether `control-panel` is the *primary* interface (cloud-first) or a rarely-used escape
  hatch (local-first).
- Whether `org-watch` reports on the bot's autonomous work (cloud-first) or on your own local
  drift (local-first) — same spine, different emphasis.
- How much unattended-loop budget/pool management (`develop --loop @nightly`, subscription
  pool exhaustion handling) matters vs. is dead weight.

## Current state (unresolved)

`claude-config`'s `develop/SKILL.md` currently ships **local-first** as a placeholder default,
explicitly flagged as provisional pending this decision. Revisit here when ready; the fix is a
small edit to that skill's locus router, not a rewrite.
