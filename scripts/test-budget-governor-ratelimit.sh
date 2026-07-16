#!/usr/bin/env bash
# Unit-tests budget-governor.yml's "ratelimit" step (issue #275): scans recent
# failed Claude-workflow runs for a live `rate_limit_event`/`resetsAt` and
# surfaces it as `resets_at`, independent of the runner-minute token bucket.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

WF=.github/workflows/budget-governor.yml
ratelimit_run=$(yq -r '.jobs.govern.steps[] | select(.id == "ratelimit") | .run' "$WF")

run_case() {
  local name="$1" gh_body="$2" expect="$3" out code outfile
  outfile=$(mktemp)
  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() { eval "$gh_body"; }
  export -f gh
  export gh_body
  out=$(REPOS="repo-a" CLAUDE_WF_RE="claude|security review|fixer|issue build|deep audit|org consistency" \
    RATE_LIMIT_LOOKBACK_HOURS=6 RATE_LIMIT_MAX_RUNS_SCANNED=30 \
    GITHUB_OUTPUT="$outfile" bash -c "$ratelimit_run" 2>&1)
  code=$?
  unset -f gh
  unset gh_body
  got=$(grep '^resets_at=' "$outfile" | cut -d= -f2-)
  rm -f "$outfile"
  if [ "$code" -ne 0 ]; then
    bad "$name: step exited $code — $out"
  elif [ "$got" = "$expect" ]; then
    note "$name -> resets_at=$got"
  else
    bad "$name: expected resets_at=$expect, got '$got' (log: $out)"
  fi
}

echo "[1/3] no failed runs -> no signal"
run_case "no failures" '
  case "$1 $2" in
    "run list") echo "[]" ;;
    *) echo "[]" ;;
  esac' "0"

echo "[2/3] failed run whose log carries a FUTURE five-hour resetsAt -> surfaced"
future_epoch=4102444800 # 2100-01-01, always future
run_case "live rate limit, future resetsAt" '
  case "$1 $2" in
    "run list") echo "[{\"databaseId\":111,\"workflowName\":\"security review\",\"conclusion\":\"failure\"}]" ;;
    "run view") echo "{\"type\":\"rate_limit_event\",\"rateLimitType\":\"five_hour\",\"resetsAt\":'"$future_epoch"'}" ;;
    *) echo "[]" ;;
  esac' "$future_epoch"

echo "[3/3] failed run whose log carries a PAST resetsAt -> stale, not surfaced"
run_case "stale rate limit, past resetsAt" '
  case "$1 $2" in
    "run list") echo "[{\"databaseId\":222,\"workflowName\":\"issue build\",\"conclusion\":\"failure\"}]" ;;
    "run view") echo "{\"type\":\"rate_limit_event\",\"rateLimitType\":\"five_hour\",\"resetsAt\":1}" ;;
    *) echo "[]" ;;
  esac' "0"

if [ "$fail" -eq 0 ]; then
  echo "All budget-governor rate-limit tests passed."
else
  echo "budget-governor rate-limit tests FAILED." >&2
fi
exit "$fail"
