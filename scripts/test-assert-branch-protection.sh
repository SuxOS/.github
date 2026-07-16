#!/usr/bin/env bash
# Unit-tests assert-branch-protection's fail-open/fail-closed decision logic
# (.github/actions/assert-branch-protection/check.sh) against canned `gh api`
# fixtures, with no network. This is the test called out as missing in issue
# #227: the action unions two governance surfaces (classic branch protection +
# rulesets) with different fail-open/fail-closed behavior per surface, and a
# regression here would silently let ungated merges through — exactly the kind
# of bug the action's own comments say already happened live once.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
CHECK_SH="$(pwd)/.github/actions/assert-branch-protection/check.sh"
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

# $1 = case name, $2..= gh mock body, run check.sh, print stdout+stderr to $out,
# exit code to $code.
run_case() {
  local name="$1" gh_body="$2"
  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() { eval "$gh_body"; }
  export -f gh
  export gh_body
  out=$(GITHUB_REPOSITORY=SuxOS/example BASE_BRANCH=main REQUIRED_GATES=$'CI\nsecurity-review' \
    bash "$CHECK_SH" 2>&1)
  code=$?
  unset gh_body
  echo "  [$name] exit=$code"
}

echo "[1/5] both surfaces unreadable (403/network) -> fail OPEN (warn, exit 0)"
run_case "both-403" '
  case "$2" in
    repos/*/branches/*/protection) return 1 ;;
    repos/*/rules/branches/*) return 1 ;;
  esac'
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '::warning::could not READ'; then
  note "fails open with a warning when neither surface is readable"
else
  bad "expected exit 0 + ::warning:: when both surfaces 403, got exit=$code out=$out"
fi

echo "[2/5] rulesets readable, required gate missing -> fail CLOSED (error, exit 1)"
run_case "rules-ok-missing-gate" '
  case "$2" in
    repos/*/branches/*/protection) return 1 ;;
    repos/*/rules/branches/*) echo "[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"CI\"}]}}]" ;;
  esac'
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q '::error::.*security-review'; then
  note "fails closed and names the missing gate when rulesets omit it"
else
  bad "expected exit 1 + ::error:: naming security-review, got exit=$code out=$out"
fi

echo "[3/5] rulesets readable, both gates present -> pass (exit 0, no error)"
run_case "rules-ok-all-present" '
  case "$2" in
    repos/*/branches/*/protection) return 1 ;;
    repos/*/rules/branches/*) echo "[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"CI\"},{\"context\":\"security-review\"}]}}]" ;;
  esac'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::error::'; then
  note "passes cleanly when rulesets require every gate"
else
  bad "expected exit 0 with no ::error::, got exit=$code out=$out"
fi

echo "[4/5] classic protection OK but rulesets unreadable -> still fails OPEN (rules_ok alone gates read_ok)"
run_case "protection-ok-rules-403" '
  case "$2" in
    repos/*/branches/*/protection) echo "{\"required_status_checks\":{\"contexts\":[\"CI\",\"security-review\"]}}" ;;
    repos/*/rules/branches/*) return 1 ;;
  esac'
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '::warning::could not READ'; then
  note "documented behavior: a readable classic-protection surface does not by itself flip read_ok — only rulesets do (token can never read classic protection live, per check.sh's comment)"
else
  bad "expected exit 0 + ::warning:: (rules_ok drives read_ok, not protection), got exit=$code out=$out"
fi

echo "[5/5] rulesets return malformed JSON -> does not silently die under bash -e/pipefail"
run_case "rules-malformed-json" '
  case "$2" in
    repos/*/branches/*/protection) return 1 ;;
    repos/*/rules/branches/*) echo "not json" ;;
  esac'
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q '::error::'; then
  note "malformed ruleset JSON is treated as zero gates found -> missing-gates path, not a silent crash"
else
  bad "expected a clean exit=1 with ::error:: (missing gates), not a silent bash -e death; got exit=$code out=$out"
fi

[ "$fail" -eq 0 ] && { echo "assert-branch-protection: PASS"; exit 0; } || { echo "assert-branch-protection: FAIL"; exit 1; }
