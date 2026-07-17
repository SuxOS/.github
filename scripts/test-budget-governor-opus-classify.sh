#!/usr/bin/env bash
# Unit-tests budget-governor.yml's OPUS_WF_RE classification (issues #307/#308):
# the regex guesses opus-vs-sonnet tier from a workflow's display NAME (no
# `model:` input is visible to the rollup), and a sonnet-pinned self-fixer-*.yml
# cadence tier must be excluded even though its name still contains "fixer".
#
# This exact regression happened twice: #292/#295 special-cased out
# self-fixer-hourly.yml ("Self fixer (hourly, shallow)") by a literal "(hourly"
# name substring, then PR #297 renamed/split it into self-fixer-30m.yml ("Self
# fixer (30m, bugs+feats)") and self-fixer-bugs.yml ("Self fixer (15m, bugs
# only)") the same day, silently un-excluding both. The fix generalizes the
# lookahead to any `fixer` name immediately followed by a cadence-duration
# marker ("(<N>m" or "(hourly"), not one hardcoded literal.
#
# MUST be updated (and re-run) whenever a self-fixer-*.yml is renamed or a
# cadence tier is added/removed — that's exactly the class of change that
# broke this twice.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

WF=.github/workflows/budget-governor.yml
opus_re=$(yq -r '.env.OPUS_WF_RE' "$WF")

check() {
  local name="$1" expect="$2" got
  got=$(jq -n --arg n "$name" --arg re "$opus_re" 'if ($n | test($re; "i")) then "opus" else "sonnet" end')
  got=${got//\"/}
  if [ "$got" = "$expect" ]; then
    note "'$name' -> $got"
  else
    bad "'$name': expected $expect, got $got"
  fi
}

echo "[1/7] bare deep/1h tier 'Self fixer' -> opus (default model)"
check "Self fixer" "opus"

echo "[2/7] 'Self fixer (30m, bugs+feats)' (self-fixer-30m.yml, model: sonnet) -> sonnet"
check "Self fixer (30m, bugs+feats)" "sonnet"

echo "[3/7] 'Self fixer (15m, bugs only)' (self-fixer-bugs.yml, model: sonnet) -> sonnet"
check "Self fixer (15m, bugs only)" "sonnet"

echo "[4/7] legacy 'Self fixer (hourly, shallow)' name still excluded -> sonnet"
check "Self fixer (hourly, shallow)" "sonnet"

echo "[5/7] fixer.yml's own reusable-def name -> opus (no cadence suffix)"
check "Fixer — propose work as issues (reusable)" "opus"

echo "[6/7] 'Deep audit (nightly)' -> opus"
check "Deep audit (nightly)" "opus"

echo "[7/7] 'Org consistency (weekly)' -> opus"
check "Org consistency (weekly)" "opus"

if [ "$fail" -eq 0 ]; then
  echo "All budget-governor opus-classification tests passed."
else
  echo "budget-governor opus-classification tests FAILED." >&2
fi
exit "$fail"
