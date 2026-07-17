#!/usr/bin/env bash
# Unit-tests detect-unreachable-checks's reachability-guard logic
# (.github/actions/detect-unreachable-checks/check.sh, SuxOS/.github#323)
# against canned `gh`/`gh api` fixtures, with no network. Covers the
# settle-gate (fresh commit, in-flight checks) that must never report a fresh
# PR as jammed, the fail-safe paths (unreadable rulesets/commits must not be
# reported as a jam), and the actual required-minus-reported diff including
# the " / "-segment matching shared with assert-branch-protection.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
CHECK_SH="$(pwd)/.github/actions/detect-unreachable-checks/check.sh"
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

OLD_DATE=$(date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ)
FRESH_DATE=$(date -u -d "-1 minute" +%Y-%m-%dT%H:%M:%SZ)

# $1 = case name, $2 = gh mock body. Populates $out/$code.
run_case() {
  local name="$1" gh_body="$2"
  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() { eval "$gh_body"; }
  export -f gh
  export gh_body
  out=$(GH_REPO=SuxOS/example GRACE_MINUTES=30 PR_LIMIT=50 bash "$CHECK_SH" 2>&1)
  code=$?
  unset -f gh
  unset gh_body
  echo "  [$name] exit=$code"
}

echo "[1/9] gh pr list fails -> fail OPEN (no findings, exit 0)"
run_case "pr-list-fails" '
  case "$1" in
    pr) return 1 ;;
  esac'
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '::warning::gh pr list failed'; then
  note "an API blip enumerating PRs is not reported as a jam"
else
  bad "expected exit 0 + warning, got exit=$code out=$out"
fi

echo "[2/9] no open PRs -> exit 0, nothing to report"
run_case "no-prs" '
  case "$1" in
    pr) echo "[]" ;;
  esac'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::error::'; then
  note "zero open PRs is a clean no-op"
else
  bad "expected exit 0 with no ::error::, got exit=$code out=$out"
fi

echo "[3/9] rulesets unreadable for base -> skip PR, fail OPEN"
run_case "rules-unreadable" '
  case "$1" in
    pr) echo "[{\"number\":1,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]" ;;
    api) case "$2" in
           repos/*/rules/branches/*) return 1 ;;
         esac ;;
  esac'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::error::'; then
  note "unreadable rulesets skips the PR instead of reporting a jam"
else
  bad "expected exit 0 with no ::error::, got exit=$code out=$out"
fi

echo "[4/9] no required contexts on base -> skip PR, exit 0"
run_case "no-required" '
  case "$1" in
    pr) echo "[{\"number\":1,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]" ;;
    api) case "$2" in
           repos/*/rules/branches/*) echo "[]" ;;
         esac ;;
  esac'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::error::'; then
  note "no required contexts means nothing to check"
else
  bad "expected exit 0 with no ::error::, got exit=$code out=$out"
fi

echo "[5/9] head commit is inside the grace window -> settle-gate skips it (never reports a fresh PR as jammed)"
run_case "fresh-commit" "
  case \"\$1\" in
    pr) echo '[{\"number\":1,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"security-review\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$FRESH_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -qi 'may still be settling'; then
  note "a commit inside the grace window is not reported as a jam"
else
  bad "expected exit 0 + settling message, got exit=$code out=$out"
fi

echo "[6/9] checks still in flight on head -> not settled, skip"
run_case "checks-pending" "
  case \"\$1\" in
    pr) echo '[{\"number\":1,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"security-review\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[{\"name\":\"security-review\",\"status\":\"in_progress\"}]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -qi 'not settled yet'; then
  note "an in-flight check-run defers the verdict instead of reporting a jam"
else
  bad "expected exit 0 + not-settled message, got exit=$code out=$out"
fi

echo "[7/9] all required contexts reported (exact + prefix-drift) -> reachable, exit 0"
run_case "reachable" "
  case \"\$1\" in
    pr) echo '[{\"number\":1,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"CI\"},{\"context\":\"security-review\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[{\"name\":\"CI\",\"status\":\"completed\"},{\"name\":\"audit / security-review\",\"status\":\"completed\"}]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::error::'; then
  note "exact match + ' / '-prefix drift both count as reachable, no jam reported"
else
  bad "expected exit 0 with no ::error::, got exit=$code out=$out"
fi

echo "[8/9] required context never reported, no disabled workflow found -> real jam (exit 1, generic remedy)"
run_case "never-reporting-generic" "
  case \"\$1\" in
    pr) echo '[{\"number\":7,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"pin-consistency\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/actions/workflows) echo '{\"workflows\":[{\"name\":\"pin-consistency\",\"state\":\"active\"}]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q "::error::PR #7.*pin-consistency" 2>/dev/null || { [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q '::error::PR #7'; }; then
  if printf '%s' "$out" | grep -q "path-filtered required workflow"; then
    note "a never-reporting context with no disabled workflow gets the generic path-filter/onboarding remedy"
  else
    bad "expected the generic remedy text, got out=$out"
  fi
else
  bad "expected exit 1 + ::error:: naming PR #7, got exit=$code out=$out"
fi

echo "[9/9] required context's workflow is disabled_manually -> real jam (exit 1, disabled-workflow remedy)"
run_case "never-reporting-disabled" "
  case \"\$1\" in
    pr) echo '[{\"number\":9,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"pin-consistency\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/actions/workflows) echo '{\"workflows\":[{\"name\":\"pin-consistency\",\"state\":\"disabled_manually\"}]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'manually disabled'; then
  note "a disabled required workflow is classified and named in the remedy"
else
  bad "expected exit 1 + 'manually disabled' remedy, got exit=$code out=$out"
fi

[ "$fail" -eq 0 ] && { echo "detect-unreachable-checks: PASS"; exit 0; } || { echo "detect-unreachable-checks: FAIL"; exit 1; }
