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

# $1 = case name, $2 = gh mock body. Populates $out/$code/$gh_output (the
# GITHUB_OUTPUT file's contents, for the generic-unreachable-prs handoff).
run_case() {
  local name="$1" gh_body="$2" out_file
  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() { eval "$gh_body"; }
  export -f gh
  export gh_body
  out_file=$(mktemp)
  out=$(GH_REPO=SuxOS/example GRACE_MINUTES=30 PR_LIMIT=50 GITHUB_OUTPUT="$out_file" bash "$CHECK_SH" 2>&1)
  code=$?
  gh_output=$(cat "$out_file" 2>/dev/null || true)
  rm -f "$out_file"
  unset -f gh
  unset gh_body
  echo "  [$name] exit=$code"
}

echo "[1/13] gh pr list fails -> fail OPEN (no findings, exit 0)"
run_case "pr-list-fails" '
  case "$1" in
    pr) return 1 ;;
  esac'
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '::warning::gh pr list failed'; then
  note "an API blip enumerating PRs is not reported as a jam"
else
  bad "expected exit 0 + warning, got exit=$code out=$out"
fi

echo "[2/13] no open PRs -> exit 0, nothing to report"
run_case "no-prs" '
  case "$1" in
    pr) echo "[]" ;;
  esac'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::error::'; then
  note "zero open PRs is a clean no-op"
else
  bad "expected exit 0 with no ::error::, got exit=$code out=$out"
fi

echo "[3/13] rulesets unreadable for base -> skip PR, fail OPEN"
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

echo "[4/13] no required contexts on base -> skip PR, exit 0"
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

echo "[5/13] head commit is inside the grace window -> settle-gate skips it (never reports a fresh PR as jammed)"
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

echo "[6/13] checks still in flight on head -> not settled, skip"
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

echo "[7/13] all required contexts reported (exact + prefix-drift) -> reachable, exit 0"
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

echo "[8/13] required context never reported, no disabled workflow found -> real jam (exit 1, generic remedy)"
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
if [ "$gh_output" = "generic-unreachable-prs=7" ]; then
  note "a pure-generic PR is handed off via generic-unreachable-prs (#379)"
else
  bad "expected GITHUB_OUTPUT 'generic-unreachable-prs=7', got: $gh_output"
fi

echo "[9/13] required context's workflow is disabled_manually -> real jam (exit 1, disabled-workflow remedy)"
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
if [ "$gh_output" = "generic-unreachable-prs=" ]; then
  note "a pure-disabled-workflow PR is excluded from generic-unreachable-prs (#379, needs re-enabling instead)"
else
  bad "expected GITHUB_OUTPUT 'generic-unreachable-prs=' (empty), got: $gh_output"
fi

echo "[10/13] one gate disabled + one gate generic on the SAME PR -> excluded from generic-unreachable-prs (mixed cause)"
run_case "never-reporting-mixed" "
  case \"\$1\" in
    pr) echo '[{\"number\":11,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"pin-consistency\"},{\"context\":\"disabled-gate\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/actions/workflows) echo '{\"workflows\":[{\"name\":\"disabled-gate\",\"state\":\"disabled_manually\"}]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 1 ] && [ "$gh_output" = "generic-unreachable-prs=" ]; then
  note "a PR with a mixed disabled+generic cause is left for the operator, not auto-retried"
else
  bad "expected exit 1 + empty generic-unreachable-prs, got exit=$code gh_output=$gh_output"
fi

echo "[11/13] two PRs, only one pure-generic -> only that one is handed off"
run_case "never-reporting-two-prs" "
  case \"\$1\" in
    pr) echo '[{\"number\":7,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"},{\"number\":9,\"baseRefName\":\"main\",\"headRefOid\":\"def456\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"pin-consistency\"}]}}]' ;;
           repos/*/commits/abc123/check-runs) echo '{\"check_runs\":[]}' ;;
           repos/*/commits/def456/check-runs) echo '{\"check_runs\":[{\"name\":\"pin-consistency\",\"status\":\"completed\"}]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/actions/workflows) echo '{\"workflows\":[{\"name\":\"pin-consistency\",\"state\":\"active\"}]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 1 ] && [ "$gh_output" = "generic-unreachable-prs=7" ]; then
  note "generic-unreachable-prs stays scoped to the PR(s) that actually qualify (PR #9 reported and is reachable)"
else
  bad "expected exit 1 + generic-unreachable-prs=7, got exit=$code gh_output=$gh_output"
fi

echo "[12/13] two flagged PRs in one run -> actions/workflows fetched once, not re-fetched per PR (#386)"
WF_CALLS_FILE=$(mktemp)
echo 0 > "$WF_CALLS_FILE"
run_case "workflows-json-cached-across-prs" "
  case \"\$1\" in
    pr) echo '[{\"number\":11,\"baseRefName\":\"main\",\"headRefOid\":\"abc111\"},{\"number\":12,\"baseRefName\":\"main\",\"headRefOid\":\"abc222\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"pin-consistency\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/actions/workflows)
             c=\$(cat '$WF_CALLS_FILE'); echo \$((c + 1)) > '$WF_CALLS_FILE'
             echo '{\"workflows\":[{\"name\":\"pin-consistency\",\"state\":\"active\"}]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
wf_calls=$(cat "$WF_CALLS_FILE")
rm -f "$WF_CALLS_FILE"
if [ "$code" -eq 1 ] && [ "$wf_calls" -eq 1 ]; then
  note "actions/workflows fetched exactly once across both flagged PRs, not re-fetched per PR"
else
  bad "expected exactly 1 actions/workflows call for 2 flagged PRs, got $wf_calls (exit=$code)"
fi

echo "[13/13] required context is a longer '<workflow> / <job>' string, disabled workflow name is the shorter prefix -> classified as disabled (#380)"
run_case "never-reporting-disabled-prefix-name" "
  case \"\$1\" in
    pr) echo '[{\"number\":13,\"baseRefName\":\"main\",\"headRefOid\":\"abc123\"}]' ;;
    api) case \"\$2\" in
           repos/*/rules/branches/*) echo '[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"pin-consistency / verify\"}]}}]' ;;
           repos/*/commits/*/check-runs) echo '{\"check_runs\":[]}' ;;
           repos/*/commits/*/status) echo '{\"statuses\":[]}' ;;
           repos/*/actions/workflows) echo '{\"workflows\":[{\"name\":\"pin-consistency\",\"state\":\"disabled_manually\"}]}' ;;
           repos/*/commits/*) echo '{\"commit\":{\"committer\":{\"date\":\"$OLD_DATE\"}}}' ;;
         esac ;;
  esac"
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'manually disabled'; then
  note "a disabled workflow whose short name is a '<workflow> / <job>' prefix of the required context is classified and named in the remedy"
else
  bad "expected exit 1 + 'manually disabled' remedy, got exit=$code out=$out"
fi
if [ "$gh_output" = "generic-unreachable-prs=" ]; then
  note "a pure-disabled-workflow PR (prefix-matched) is excluded from generic-unreachable-prs"
else
  bad "expected GITHUB_OUTPUT 'generic-unreachable-prs=' (empty), got: $gh_output"
fi

[ "$fail" -eq 0 ] && { echo "detect-unreachable-checks: PASS"; exit 0; } || { echo "detect-unreachable-checks: FAIL"; exit 1; }
