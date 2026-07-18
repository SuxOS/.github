#!/usr/bin/env bash
# Unit-tests budget-governor.yml's "sweep" step cap-hit guard (#443): the per-repo
# `gh run list --limit 1001` call (one past the real 1000 cap, same shape as the
# rate-limit scan's #438 fix and fabric-health's collectors) must fail the whole job
# closed when a repo's true run count in the lookback window exceeds the cap, rather
# than silently governing on a truncated page. This step's output feeds
# opus_avail_min/total_avail_min -> level directly, gating the ENTIRE autonomy
# pipeline, so (unlike the best-effort rate-limit scan, which only warns) an
# undercount here must not be allowed to read as a falsely-green level.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

WF=.github/workflows/budget-governor.yml
sweep_run=$(yq -r '.jobs.govern.steps[] | select(.id == "sweep") | .run' "$WF")

run_case() {
  local name="$1" gh_body="$2" expect_code="$3" expect_pattern="$4" out code outfile
  outfile=$(mktemp)
  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() { eval "$gh_body"; }
  export -f gh
  export gh_body
  # bash -e -c, not bare bash -c (#411): the runner's actual shell for this step is
  # `bash -e {0}`, so the harness must reproduce errexit semantics or it misses any
  # bug that only manifests under -e (#404).
  out=$(REPOS="repo-a" LOOKBACK_DAYS=7 \
    CLAUDE_WF_RE="claude|security review|fixer|issue build|deep audit|org consistency" \
    OPUS_WF_RE="deep audit|org consistency|fixer(?! ?\\((?:\\d+m|hourly))" \
    OPUS_BUDGET_MIN=900 TOTAL_BUDGET_MIN=6000 YELLOW_FRACTION=0.75 \
    GITHUB_OUTPUT="$outfile" bash -e -c "$sweep_run" 2>&1)
  code=$?
  unset -f gh
  unset gh_body
  rm -f "$outfile"
  if [ "$code" -ne "$expect_code" ]; then
    bad "$name: expected exit $expect_code, got $code (log: $out)"
  elif ! grep -q "$expect_pattern" <<<"$out"; then
    bad "$name: expected output to match '$expect_pattern' (log: $out)"
  else
    note "$name -> exit $code"
  fi
}

echo "[1/3] repo under the cap -> succeeds, computes a level"
run_case "under cap" '
  case "$1 $2" in
    "run list") jq -nc "[range(3) | {workflowName: \"claude\", conclusion: \"success\", status: \"completed\", startedAt: \"2026-07-01T00:00:00Z\", updatedAt: \"2026-07-01T00:05:00Z\"}]" ;;
    *) echo "[]" ;;
  esac' 0 "level="

echo "[2/3] repo returns >1000 runs (past the --limit 1001 cap probe) -> fails closed, does not silently undercount"
run_case "cap hit" '
  case "$1 $2" in
    "run list") jq -nc "[range(1001) | {workflowName: \"claude\", conclusion: \"success\", status: \"completed\", startedAt: \"2026-07-01T00:00:00Z\", updatedAt: \"2026-07-01T00:05:00Z\"}]" ;;
    *) echo "[]" ;;
  esac' 1 "has >1000 runs"

echo "[3/3] gh run list itself fails -> still fails closed (pre-existing behavior preserved)"
run_case "gh failure" '
  case "$1 $2" in
    "run list") return 1 ;;
    *) echo "[]" ;;
  esac' 1 "gh run list failed"

if [ "$fail" -eq 0 ]; then
  echo "All budget-governor sweep cap-hit tests passed."
else
  echo "budget-governor sweep cap-hit tests FAILED." >&2
fi
exit "$fail"
