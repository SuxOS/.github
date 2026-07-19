#!/usr/bin/env bash
#
# Chaos-injection primitive for SuxOS/.github#490 (canary caller-conformance self-test).
#
# #490 asks for a persistent canary repo + scheduled job that periodically injects a known
# drift class, confirms check-caller-conformance.sh flags it, then reverts — end-to-end
# proof the detect/remediate loop still works, not just synthetic-fixture unit tests. That
# needs a real provisioned repo first (#490 slice 1, explicitly needs-human — this repo has
# no access to create one), so this ships only the unit-testable inject/revert primitive
# (#490 slice 2): the actual scheduled live-repo job (slice 3) and the fabric-health gauge
# (slice 4) are deliberately deferred until a canary repo exists to run them against.
#
# Injects (and reverts) exactly the three known drift classes check-caller-conformance.sh
# detects (#346): a missing canonical stub file, a dead workflow_run autofix stub (the
# R5/#263 class), and a stale non-@main first-party ref. Operates on any
# .github/workflows/-shaped directory — a synthetic fixture in tests today, a real canary
# repo's checkout once #490 slice 1 lands. Idempotent guards throughout (refuses to
# double-inject or to revert something it didn't inject) so a scheduled job that reruns
# mid-failure can't compound damage.
#
# Usage:
#   inject-caller-drift.sh <workflows-dir> inject missing-stub [stub-name]   (default: audit)
#   inject-caller-drift.sh <workflows-dir> revert missing-stub [stub-name]
#   inject-caller-drift.sh <workflows-dir> inject dead-stub
#   inject-caller-drift.sh <workflows-dir> revert dead-stub
#   inject-caller-drift.sh <workflows-dir> inject stale-ref [stub-name]      (default: audit)
#   inject-caller-drift.sh <workflows-dir> revert stale-ref [stub-name]
#
# `revert missing-stub` regenerates ONLY the affected file from a fresh scaffold-caller.sh
# run into a scratch dir (not a whole-tree -f overwrite), so it can't clobber a repo's other,
# possibly-customised stubs (e.g. a non-default wrangler-config baked into ci.yml).
set -euo pipefail

WFDIR="${1:?usage: inject-caller-drift.sh <workflows-dir> <inject|revert> <class> [stub-name]}"
ACTION="${2:?usage: inject-caller-drift.sh <workflows-dir> <inject|revert> <class> [stub-name]}"
CLASS="${3:?usage: inject-caller-drift.sh <workflows-dir> <inject|revert> <class> [stub-name]}"
NAME="${4:-audit}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAFFOLD="$ROOT/scripts/scaffold-caller.sh"
[ -f "$SCAFFOLD" ] || { echo "inject-caller-drift: cannot find scaffold-caller.sh at $SCAFFOLD" >&2; exit 2; }
[ -d "$WFDIR" ] || { echo "inject-caller-drift: no such workflows dir: $WFDIR" >&2; exit 2; }

DEAD_STUB_MARKER="# injected by inject-caller-drift.sh (SuxOS/.github#490 chaos self-test)"
DEAD_STUB_FILE="$WFDIR/claude-autofix.yml"

case "$ACTION-$CLASS" in
  inject-missing-stub)
    f="$WFDIR/$NAME.yml"
    [ -f "$f" ] || { echo "inject-caller-drift: $f does not exist — nothing to remove" >&2; exit 1; }
    rm -f "$f"
    echo "injected: removed $f (MISSING drift class)"
    ;;
  revert-missing-stub)
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    bash "$SCAFFOLD" -o "$scratch" -w "" >/dev/null
    [ -f "$scratch/$NAME.yml" ] || { echo "inject-caller-drift: scaffold-caller.sh does not emit $NAME.yml — bad stub name?" >&2; exit 1; }
    cp "$scratch/$NAME.yml" "$WFDIR/$NAME.yml"
    echo "reverted: restored canonical $WFDIR/$NAME.yml"
    ;;
  inject-dead-stub)
    [ -f "$DEAD_STUB_FILE" ] && { echo "inject-caller-drift: $DEAD_STUB_FILE already exists — refusing to clobber" >&2; exit 1; }
    cat > "$DEAD_STUB_FILE" <<YAML
$DEAD_STUB_MARKER
name: Claude autofix
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  autofix:
    uses: SuxOS/.github/.github/workflows/claude-autofix.yml@main
    secrets: inherit
YAML
    echo "injected: wrote dead workflow_run stub $DEAD_STUB_FILE (DEAD drift class)"
    ;;
  revert-dead-stub)
    [ -f "$DEAD_STUB_FILE" ] || { echo "inject-caller-drift: $DEAD_STUB_FILE does not exist — nothing to revert" >&2; exit 1; }
    head -1 "$DEAD_STUB_FILE" | grep -qF "$DEAD_STUB_MARKER" \
      || { echo "inject-caller-drift: $DEAD_STUB_FILE is not our injected marker — refusing to delete a real file" >&2; exit 1; }
    rm -f "$DEAD_STUB_FILE"
    echo "reverted: removed injected $DEAD_STUB_FILE"
    ;;
  inject-stale-ref)
    f="$WFDIR/$NAME.yml"
    [ -f "$f" ] || { echo "inject-caller-drift: $f does not exist" >&2; exit 1; }
    grep -qE "workflows/$NAME\.yml@main" "$f" \
      || { echo "inject-caller-drift: $f has no @main first-party ref to stale-pin (already stale, or wrong stub name?)" >&2; exit 1; }
    sed -i "s#workflows/$NAME.yml@main#workflows/$NAME.yml@v0.0.0-chaos-test#" "$f"
    echo "injected: pinned $f off @main (STALE-REF drift class)"
    ;;
  revert-stale-ref)
    f="$WFDIR/$NAME.yml"
    [ -f "$f" ] || { echo "inject-caller-drift: $f does not exist" >&2; exit 1; }
    grep -qE "workflows/$NAME\.yml@v0\.0\.0-chaos-test" "$f" \
      || { echo "inject-caller-drift: $f is not pinned to our injected @v0.0.0-chaos-test ref — refusing to touch it" >&2; exit 1; }
    sed -i "s#workflows/$NAME.yml@v0.0.0-chaos-test#workflows/$NAME.yml@main#" "$f"
    echo "reverted: restored $f to @main"
    ;;
  *)
    echo "inject-caller-drift: unknown action/class combo '$ACTION $CLASS' (expected inject|revert x missing-stub|dead-stub|stale-ref)" >&2
    exit 1
    ;;
esac
