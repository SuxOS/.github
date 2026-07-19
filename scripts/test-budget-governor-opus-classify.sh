#!/usr/bin/env bash
# Unit-tests budget-governor.yml's OPUS_WF_RE classification (issues #307/#308/#369):
# the regex guesses opus-vs-sonnet tier from a workflow's display NAME (no
# `model:` input is visible to the rollup).
#
# #307/#308: #292/#295 special-cased out self-fixer-hourly.yml ("Self fixer (hourly,
# shallow)") by a literal "(hourly" name substring, then PR #297 renamed/split it into
# self-fixer-30m.yml ("Self fixer (30m, bugs+feats)") and self-fixer-bugs.yml ("Self
# fixer (15m, bugs only)") the same day, silently un-excluding both.
#
# #369: fixer.yml's `model` default flipped opus->sonnet in #286, then back to sonnet
# (the current, org-wide-directive state) in #373 — but OPUS_WF_RE and this test still
# expected the bare "Self fixer"/"Fixer" (no cadence suffix) deep tier to classify as
# opus, which #373 made false (self-fixer.yml explicitly pins `model: sonnet`). No fixer
# tier is opus-classified by default any more; only deep-audit/org-consistency are. See
# model-policy.json (#369) for the single-source directive this must stay in sync with.
#
# MUST be updated (and re-run) whenever a self-fixer-*.yml is renamed, a cadence tier is
# added/removed, or a fixer/issue-build model default changes — that's exactly the class
# of change that has broken this three times now.
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

echo "[1/7] bare deep/1h tier 'Self fixer' -> sonnet (model: sonnet, #373)"
check "Self fixer" "sonnet"

echo "[2/7] 'Self fixer (30m, bugs+feats)' (self-fixer-30m.yml, model: sonnet) -> sonnet"
check "Self fixer (30m, bugs+feats)" "sonnet"

echo "[3/7] 'Self fixer (15m, bugs only)' (self-fixer-bugs.yml, model: sonnet) -> sonnet"
check "Self fixer (15m, bugs only)" "sonnet"

echo "[4/7] legacy 'Self fixer (hourly, shallow)' name still excluded -> sonnet"
check "Self fixer (hourly, shallow)" "sonnet"

echo "[5/7] fixer.yml's own reusable-def name -> sonnet (default model, #373)"
check "Fixer — propose work as issues (reusable)" "sonnet"

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
