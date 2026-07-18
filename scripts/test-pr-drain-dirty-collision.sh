#!/usr/bin/env bash
# Unit-tests pr-drain.yml's DIRTY-CONFLICT sweep for the sibling hot-file-collision
# diagnostic (SuxOS/.github#437).
#
# Even with the requeue cap fixed (#434), issue-build.yml's `parallel-batches` default
# still allows 2 concurrently-open bot/issue-build-* PRs by design. If they happen to
# pick issues that both touch the same file, the second to merge goes DIRTY and this
# sweep recovers it (close + requeue) exactly as it always did — but until now that
# recovery gave no signal distinguishing "collided with a sibling builder PR" (the
# residual, wasted-build-spend failure mode #437 describes) from ordinary drift against
# main. The fix adds a best-effort note to the closing comment when the DIRTY PR's
# changed files (from the `files` field now included in the batch `gh pr list` call)
# overlap with another still-open bot/issue-build-* PR's changed files.
#
# Extracts the ACTUAL fan-out script shipped in the workflow (no hand-copied stand-in —
# same principle as test-scaffold-caller-regression.sh) and drives it with fixture
# PR lists via an exported `gh` shell function, asserting the note appears only when a
# real file overlap exists.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq not on PATH" >&2; exit 1; }

wf=".github/workflows/pr-drain.yml"
drain_run="$(yq -r '.jobs.drain.steps[] | select(.id == "drain") | .run' "$wf")"

if ! printf '%s' "$drain_run" | grep -q 'Hot-file collision'; then
  echo "FAIL: could not extract pr-drain drain script (anchors moved?)" >&2
  exit 1
fi

pr100='{"number":100,"title":"t100","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-100","files":[{"path":"CLAUDE.md"},{"path":"foo.txt"}]}'
pr200='{"number":200,"title":"t200","isDraft":false,"labels":[],"mergeStateStatus":"CLEAN","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-200","files":[{"path":"CLAUDE.md"},{"path":"bar.txt"}]}'
pr300='{"number":300,"title":"t300","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-300","files":[{"path":"onlymine.txt"}]}'
view100='{"number":100,"body":"Closes #1","headRefName":"bot/issue-build-100","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY"}'
view300='{"number":300,"body":"Closes #3","headRefName":"bot/issue-build-300","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY"}'

# $1 = scenario name, $2 = PRS_JSON array, $3 = dirty PR number, $4 = its `gh pr view` JSON,
# $5 = comments-log path (truncated first). Runs the real extracted script.
run_scenario() {
  local prs_json="$2" dirty_n="$3" view_json="$4" log="$5"
  : > "$log"

  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() {
    case "$1 $2" in
      "pr list") printf '%s' "$PRS_JSON" ;;
      "pr view")
        if [ "$3" = "$DIRTY_N" ]; then printf '%s' "$VIEW_JSON"; else return 1; fi
        ;;
      "pr comment") printf 'COMMENT %s: %s\n' "$3" "$5" >> "$LOG" ;;
      "pr close") return 0 ;;
      "issue edit") return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f gh
  PRS_JSON="$prs_json" DIRTY_N="$dirty_n" VIEW_JSON="$view_json" LOG="$log" \
    STALE_DAYS="14" PR_LIMIT="200" DRY_RUN="false" GH_REPO="test/repo" \
    bash -e -c "$drain_run" >/dev/null 2>&1
}

echo "[1/2] DIRTY PR sharing a file with an open sibling builder PR"
log1=$(mktemp)
run_scenario "collision" "[$pr100,$pr200]" "100" "$view100" "$log1"
if grep -q 'COMMENT 100:.*Hot-file collision with sibling builder PR(s): #200 on CLAUDE.md.*#437' "$log1"; then
  note "collision note names sibling #200 and the shared file (CLAUDE.md)"
else
  bad "expected a #200/CLAUDE.md collision note in the close comment, got: $(cat "$log1")"
fi
rm -f "$log1"

echo "[2/2] DIRTY PR with no file overlap against the same open sibling"
log2=$(mktemp)
run_scenario "no-collision" "[$pr300,$pr200]" "300" "$view300" "$log2"
if grep -q 'COMMENT 300:' "$log2" && ! grep -q 'Hot-file collision' "$log2"; then
  note "no collision note when files don't overlap"
else
  bad "expected a plain close comment with no collision note, got: $(cat "$log2")"
fi
rm -f "$log2"

if [ "$fail" -eq 0 ]; then
  echo "All pr-drain DIRTY-collision tests passed."
else
  echo "pr-drain DIRTY-collision tests FAILED." >&2
fi
exit "$fail"
