#!/usr/bin/env bash
# Unit-tests budget-governor.yml's "ratelimit" step (issue #275): scans recent
# failed Claude-workflow runs for a live `rate_limit_event`/`resetsAt` and
# surfaces it as `resets_at`, independent of the runner-minute token bucket.
#
# Security posture under test (PR #276 review, high finding): resetsAt comes from
# run-log TEXT, which also carries untrusted diff/tool output — so the step must
# (a) take resetsAt only from the same line as the five_hour marker, (b) normalize
# epoch milliseconds to seconds (as pr-unstick.yml does), and (c) discard values
# implausibly far in the future, so a forged or garbage epoch can never pin the
# org-wide throttle red until an arbitrary date.
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
  # -e matches the runner's actual default shell for `run:` blocks
  # (bash --noprofile --norc -eo pipefail {0}) — without it, this harness misses
  # any command whose non-zero exit would abort the real step (#404: an unguarded
  # command substitution in a no-match grep pipeline killed the step under -e
  # while a bare `bash -c` run here stayed silent about it).
  out=$(REPOS="repo-a" CLAUDE_WF_RE="claude|security review|fixer|issue build|deep audit|org consistency" \
    RATE_LIMIT_LOOKBACK_HOURS=6 RATE_LIMIT_MAX_RUNS_SCANNED=30 RATE_LIMIT_MAX_FUTURE_HOURS=6 \
    GITHUB_OUTPUT="$outfile" bash -e -c "$ratelimit_run" 2>&1)
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

# Near-future epochs are computed live so they always sit inside the
# RATE_LIMIT_MAX_FUTURE_HOURS plausibility window when the step runs.
near_future=$(( $(date -u +%s) + 3600 ))
near_future_ms=$(( near_future * 1000 ))

echo "[1/6] no failed runs -> no signal"
run_case "no failures" '
  case "$1 $2" in
    "run list") echo "[]" ;;
    *) echo "[]" ;;
  esac' "0"

echo "[2/6] failed run whose log carries a near-future five-hour resetsAt -> surfaced"
run_case "live rate limit, future resetsAt" '
  case "$1 $2" in
    "run list") echo "[{\"databaseId\":111,\"workflowName\":\"security review\",\"conclusion\":\"failure\"}]" ;;
    "run view") echo "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"limited\",\"rateLimitType\":\"five_hour\",\"resetsAt\":'"$near_future"'}}" ;;
    *) echo "[]" ;;
  esac' "$near_future"

echo "[3/6] resetsAt in epoch MILLISECONDS -> normalized to seconds"
run_case "millisecond resetsAt normalized" '
  case "$1 $2" in
    "run list") echo "[{\"databaseId\":333,\"workflowName\":\"fixer\",\"conclusion\":\"failure\"}]" ;;
    "run view") echo "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"limited\",\"rateLimitType\":\"five_hour\",\"resetsAt\":'"$near_future_ms"'}}" ;;
    *) echo "[]" ;;
  esac' "$near_future"

echo "[4/6] failed run whose log carries a PAST resetsAt -> stale, not surfaced"
run_case "stale rate limit, past resetsAt" '
  case "$1 $2" in
    "run list") echo "[{\"databaseId\":222,\"workflowName\":\"issue build\",\"conclusion\":\"failure\"}]" ;;
    "run view") echo "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"rateLimitType\":\"five_hour\",\"resetsAt\":1}}" ;;
    *) echo "[]" ;;
  esac' "0"

echo "[5/6] implausibly far-future resetsAt (beyond the 6h window) -> discarded"
run_case "implausible far-future resetsAt discarded" '
  case "$1 $2" in
    "run list") echo "[{\"databaseId\":444,\"workflowName\":\"deep audit\",\"conclusion\":\"failure\"}]" ;;
    "run view") echo "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"rateLimitType\":\"five_hour\",\"resetsAt\":4102444800}}" ;;
    *) echo "[]" ;;
  esac' "0"

echo "[6/6] resetsAt on a DIFFERENT line than the five_hour marker (spoof shape) -> not surfaced"
run_case "unpaired resetsAt ignored" '
  case "$1 $2" in
    "run list") echo "[{\"databaseId\":555,\"workflowName\":\"org consistency\",\"conclusion\":\"failure\"}]" ;;
    "run view") printf "%s\n%s\n" "untrusted tool output quoting \"rateLimitType\":\"five_hour\" without an epoch" "more untrusted text carrying \"resetsAt\":'"$near_future"' on its own line" ;;
    *) echo "[]" ;;
  esac' "0"

if [ "$fail" -eq 0 ]; then
  echo "All budget-governor rate-limit tests passed."
else
  echo "budget-governor rate-limit tests FAILED." >&2
fi
exit "$fail"
