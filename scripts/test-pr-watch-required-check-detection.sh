#!/usr/bin/env bash
#
# Unit-tests pr-watch.yml's "Scan open PRs for stalls" step's required-check-detection
# read logic (#511). pr-watch.yml:87-98 wraps both the classic `branches/main/protection`
# and the `rules/branches/main` `gh api` reads in `if ... 2>/dev/null` — before this fix,
# there was no else/warning branch, so if BOTH reads failed (token lacking admin perms,
# transient API blip), `required_json` silently became `[]` and the `$failing` predicate
# stayed permanently false for the whole run with zero visibility that detection had
# degraded. The established pattern this file now follows (same as the sibling
# `assert-branch-protection/check.sh` and this same file's own pr-limit-truncation
# warning) is to warn loudly whenever a read that gates detection fails.
#
# Extracts the ACTUAL shell block shipped in the workflow (no hand-copied stand-in — same
# principle as test-issue-build-disposition-close.sh / test-scaffold-caller-regression.sh)
# and drives it with a mocked `gh` — no network, no live API.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq not on PATH" >&2; exit 1; }

wf=".github/workflows/pr-watch.yml"
scan_run="$(yq -r '.jobs.watch.steps[] | select(.name == "Scan open PRs for stalls") | .run' "$wf")"

if ! printf '%s' "$scan_run" | grep -q 'could not read'; then
  echo "FAIL: could not extract pr-watch.yml's scan script (anchors moved?)" >&2
  exit 1
fi

# $1 = scenario name, $2 = protection-read body ("fail" or a JSON echo command),
# $3 = rules-read body, $4 = PR list JSON. Runs the real extracted script with an
# empty PR list (the warning fires before any PR is inspected, and an empty list
# exits 0 right after, so this isolates the read-failure warning from the rest of
# the flagging logic).
run_scenario() {
  local prot_body="$1" rules_body="$2" prs_json="$3"
  local outfile
  outfile="$(mktemp)"

  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() {
    case "$1" in
      pr) [ "$2" = "list" ] && printf '%s' "$PRS_JSON" ;;
      api)
        case "$2" in
          repos/*/branches/*/protection) eval "$PROT_BODY" ;;
          repos/*/rules/branches/*) eval "$RULES_BODY" ;;
        esac
        ;;
    esac
  }
  export -f gh
  export PROT_BODY="$prot_body" RULES_BODY="$rules_body" PRS_JSON="$prs_json"

  out=$(GH_TOKEN="x" FLAG_BEHIND="true" STALE_HOURS="6" PR_LIMIT="100" \
    GITHUB_REPOSITORY="test/repo" GITHUB_OUTPUT="$outfile" \
    bash -e -c "$scan_run" 2>&1)
  code=$?
  rm -f "$outfile"
}

echo "[1/4] both branch-protection and rulesets reads fail -> ::warning:: emitted, no crash"
run_scenario 'return 1' 'return 1' '[]'
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '::warning::could not read'; then
  note "both-fail: warns and exits cleanly"
else
  bad "both-fail: expected exit 0 + ::warning:: — got exit=$code out=$out"
fi

echo "[2/4] classic protection readable, rulesets fail -> no warning (one surface is enough)"
run_scenario 'echo "{\"required_status_checks\":{\"contexts\":[\"CI\"]}}"' 'return 1' '[]'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::warning::could not read'; then
  note "protection-ok: no degraded-detection warning"
else
  bad "protection-ok: expected exit 0 with no warning — got exit=$code out=$out"
fi

echo "[3/4] rulesets readable, classic protection fails -> no warning (one surface is enough)"
run_scenario 'return 1' 'echo "[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"CI\"}]}}]"' '[]'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::warning::could not read'; then
  note "rules-ok: no degraded-detection warning"
else
  bad "rules-ok: expected exit 0 with no warning — got exit=$code out=$out"
fi

echo "[4/4] both surfaces readable -> no warning"
run_scenario 'echo "{\"required_status_checks\":{\"contexts\":[\"CI\"]}}"' \
  'echo "[{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"CI\"}]}}]"' '[]'
if [ "$code" -eq 0 ] && ! printf '%s' "$out" | grep -q '::warning::could not read'; then
  note "both-ok: no degraded-detection warning"
else
  bad "both-ok: expected exit 0 with no warning — got exit=$code out=$out"
fi

if [ "$fail" -eq 0 ]; then
  echo "All pr-watch required-check-detection tests passed."
else
  echo "pr-watch required-check-detection tests FAILED." >&2
fi
exit "$fail"
