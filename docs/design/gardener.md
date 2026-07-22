# Gardener — two-tier vault maintenance (#676)

`.github/workflows/gardener.yml` is a `workflow_call` reusable that maintains the
Obsidian-style vault repo (SuxOS/vault). Autonomy=A: it auto-applies changes and relies
on git as the undo, same posture as the rest of this pipeline.

## Split

This repo builds the reusable only. The caller stub lives in the vault repo, added by
hand outside the general build pipeline — SuxOS/vault is deliberately NOT in
`managed-repos.json`, so no other automation in this org treats it as a managed repo.

## Two tiers

- **Tier 1 (`tier: on-push`)** — deterministic, no LLM. Runs the vault's own
  `vault-lint.py` (structure ratchet), the exact-rename dead-link repair shipped in this
  repo (`scripts/gardener/relink_dead_links.py`), and `signal-rank.py`. Guards against
  re-triggering itself on its own `[gardener]` commits, and uses
  `concurrency: {group: gardener-<repo>, cancel-in-progress: false}` so overlapping
  pushes queue instead of racing.
- **Tier 2 (`tier: daily`)** — `anthropics/claude-code-action@v1` on a daily cron, cost
  bounded by `--max-turns` (default 30). Fuzzy (non-exact) dead-link repair, orphan
  weaving into MOCs, prune-to-`.trash/`, and a log append. Skips cleanly (green no-op)
  when `CLAUDE_CODE_OAUTH_TOKEN` is absent, mirroring the vault's existing
  `daily-note-ingest.yml` inert-until-token pattern. Explicitly excludes daily-note
  assimilation — that stays `daily-note-ingest.yml`'s job, not duplicated here.

## Why `.trash/`, not `Trash/`

Both vault linters already SKIP a `.trash` directory (`vault-lint.py`'s `SKIP` set and
`link-lint.py`'s `SKIP` set both include `.trash`, and dot-prefixed top-level dirs are
exempt from `vault-lint.py`'s `ALLOWED_TOP` check). Pruning into `.trash/<ISO-date>/`
via `git mv` therefore drops zero baseline churn on the lint ratchet and needs no linter
change — a `Trash/` (visible) directory would have required updating both linters' skip
sets and `ALLOWED_TOP` first.

## Why no vectorize/reindex step

The sux worker owns a durable Vectorize backfill cron (sux#1315) on its own cadence.
Coupling the gardener to that worker would create a cross-repo dependency this workflow
has no way to observe or retry cleanly — index reconciliation stays entirely the
worker's concern.

## Exact-rename repair semantics

A wikilink target is "dead" when it doesn't resolve to any existing note by exact
relative path. A dead target is "repairable" only when its basename (the last path
segment) uniquely matches exactly one note anywhere in the vault — zero or multiple
basename matches are left untouched rather than guessed at. Capped at 50 repairs per
run. Tested in `scripts/test-gardener-relink.sh` (unique-match, zero-match, multi-match,
and the cap), wired into `self-check.yml`.
