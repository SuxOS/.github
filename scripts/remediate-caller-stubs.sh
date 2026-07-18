#!/usr/bin/env bash
#
# Mechanical remediation slice of check-caller-conformance.sh's findings (#355).
#
# check-caller-conformance.sh is advisory-only by design (#346) — it can never be the thing
# that closes the loop, because a warning + step-summary row still needs a human to notice
# and act (docs/design/2026-07-16-suxos-vx-next-arc.md:47,128-130, on #263 sitting "fixed"
# for hours while every caller stayed dead). This script is the part that DOES act, but only
# for the two findings that can never be wrong to fix unattended:
#
#   (a) MISSING canonical stub — added via scaffold-caller.sh itself (single source of
#       truth, can't drift from the check). scaffold-caller.sh's own `emit()` already
#       skips any file that exists, so this can never overwrite/touch a stub the caller
#       repo already has, customized or not.
#   (b) DEAD workflow_run stub — the exact R5/#263 class: a stub that wires a SuxOS
#       reusable but triggers on workflow_run, which scaffold-caller.sh never emits
#       (claude-autofix is job-chained into ci.yml, not its own caller stub — see
#       scaffold-caller.sh's `ci` header). Removed outright.
#
# Deliberately NOT handled here (left advisory-only, needs a human):
#   - The generic non-canonical-stub case of (b) — could be an intentional repo-specific
#     workflow that happens to wire a SuxOS reusable; check-caller-conformance.sh's own
#     message says "remove if superseded, or add to scaffold-caller.sh if intended", i.e.
#     a judgment call.
#   - (c) missing `secrets: inherit` / `ready_for_review` — editing an EXISTING file's
#     content in a way that isn't a single mechanical line rewrite; left advisory-only.
#     (d) stale @ref IS handled below (#432) — a first-party SuxOS/.github `uses:` line
#     pinned to anything but @main is rewritten in place via sed, the same low-risk,
#     single-line mechanical edit as scaffold-caller.sh's own canonical stubs use.
#   - ci.yml specifically, even when wholly missing: its content bakes in a
#     --wrangler-config default (sux/wrangler.jsonc) that does not fit every caller's
#     layout (a repo with no Worker, or a Worker config at a different path) — exactly the
#     risk CLAUDE.md's caller-list section calls out. Auto-adding it here would silently
#     wire a broken dry-run-deploy step into a caller that has no Worker at all. Left for
#     the existing (a) advisory warning + a human `scaffold-caller.sh --wrangler-config`
#     pass.
#
# Usage: remediate-caller-stubs.sh <consumer-workflows-dir>
# Idempotent and side-effect-free when the tree already conforms: prints one line per
# action taken (or "nothing to remediate" style silence) and always exits 0 — the caller
# workflow decides what to do with any resulting git diff.
set -euo pipefail

WFDIR="${1:?usage: remediate-caller-stubs.sh <consumer-workflows-dir>}"
ROOT="${CALLER_CONFORMANCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCAFFOLD="$ROOT/scripts/scaffold-caller.sh"

[ -f "$SCAFFOLD" ] || { echo "remediate-caller-stubs: cannot find scaffold-caller.sh at $SCAFFOLD" >&2; exit 2; }

mkdir -p "$WFDIR"

had_ci=0
[ -f "$WFDIR/ci.yml" ] && had_ci=1

echo "-- adding any missing canonical stub (existing files are never touched) --"
bash "$SCAFFOLD" --out-dir "$WFDIR"

if [ "$had_ci" -eq 0 ] && [ -f "$WFDIR/ci.yml" ]; then
  rm -f "$WFDIR/ci.yml"
  echo "note: reverted auto-added ci.yml — its wrangler-config default may not fit this repo's layout; needs a human scaffold-caller.sh --wrangler-config pass instead. Left for (a)'s advisory warning to keep flagging it."
fi

echo "-- removing dead workflow_run stubs (R5/#263 class) --"
for f in "$WFDIR"/*.yml "$WFDIR"/*.yaml; do
  [ -e "$f" ] || continue
  uncommented="$(grep -vE '^[[:space:]]*#' "$f" || true)"
  printf '%s\n' "$uncommented" | grep -qE "uses:[[:space:]]*SuxOS/\.github/\.github/workflows/" || continue
  grep -qE '^[[:space:]]*workflow_run:' "$f" || continue
  echo "removing dead stub: $f"
  rm -f "$f"
done

echo "-- fixing stale first-party @ref pins (canonical ref is @main, #432) --"
for f in "$WFDIR"/*.yml "$WFDIR"/*.yaml; do
  [ -e "$f" ] || continue
  uncommented="$(grep -vE '^[[:space:]]*#' "$f" || true)"
  wired="$(printf '%s\n' "$uncommented" | grep -oE "uses:[[:space:]]*SuxOS/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml@[A-Za-z0-9._/-]+" || true)"
  [ -z "$wired" ] && continue
  printf '%s\n' "$wired" | grep -qvE '@main$' || continue
  echo "rewriting stale @ref pin(s) to @main: $f"
  sed -i -E 's#(uses:[[:space:]]*SuxOS/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml)@[A-Za-z0-9._/-]+#\1@main#' "$f"
done
