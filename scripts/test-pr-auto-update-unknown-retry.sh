#!/usr/bin/env bash
# Unit-tests pr-auto-update.yml's lazy-mergeStateStatus retry (SuxOS/.github#723).
#
# GitHub computes mergeStateStatus lazily: the FIRST query returns UNKNOWN and only starts
# the background computation. Because this sweep is usually the first thing to ask about a
# PR in a given window, UNKNOWN was the NORMAL response — so the BEHIND/BLOCKED filter
# matched nothing and the step exited green having updated nothing, every run, while armed
# PRs sat indefinitely under strict required-status-checks.
#
# The test that matters is the RETRY one: a fixture that reports BEHIND on the first read
# passes against the broken code too and proves nothing. Scenario [1] therefore starts from
# UNKNOWN and only yields BEHIND on re-query, and asserts the PR is actually updated.
#
# Extracts the ACTUAL shipped script (no hand-copied stand-in) and drives it with an
# exported `gh` shim. Runs it under `bash -e -c` because the runner's real default shell is
# `bash --noprofile --norc -eo pipefail`, so errexit is live even though the step's own
# `set` line only names `-uo pipefail`.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq not on PATH" >&2; exit 1; }

wf=".github/workflows/pr-auto-update.yml"
step_run="$(yq -r '.jobs.update-behind.steps[] | select(.id == "update-behind") | .run' "$wf")"
if ! printf '%s' "$step_run" | grep -q 'candidates_unknown'; then
  echo "FAIL: could not extract pr-auto-update update-behind script (anchors moved?)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# `sleep` is stubbed to nothing — the real step waits 4s per attempt, which would make this
# suite take ~12s per still-UNKNOWN scenario for no added coverage.
run_case() {
  local prs_json="$1" view_script="$2"
  : >"$work/updated"
  : >"$work/viewcalls"
  cat >"$work/gh" <<GHEOF
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "api repos/SuxOS/demo") echo "main" ;;
  "pr view") echo "\$3" >>"$work/viewcalls"; ${view_script} ;;
  "pr update-branch") echo "\$3" >>"$work/updated" ;;
  "api"*)
    # compare endpoint — always report a real 3-commit lag so the behind_by confirmation
    # isn't what decides these scenarios.
    echo "3" ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
GHEOF
  # `gh api repos/$GH_REPO --jq .default_branch` arrives as `api repos/SuxOS/demo --jq ...`,
  # so the two-word case above needs the bare form; normalize by matching on $1 only there.
  sed -i.bak 's|"api repos/SuxOS/demo")|"api repos/SuxOS/demo --jq")|' "$work/gh" && rm -f "$work/gh.bak"
  chmod +x "$work/gh"
  cat >"$work/sleep" <<'SLEEPEOF'
#!/usr/bin/env bash
exit 0
SLEEPEOF
  chmod +x "$work/sleep"
  PATH="$work:$PATH" GH_TOKEN=t GH_REPO="SuxOS/demo" PRS_JSON="$prs_json" \
    bash -e -c "$step_run" 2>&1
}

armed() {
  printf '[{"number":%s,"mergeStateStatus":"%s","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"labels":[],"headRefName":"feat/%s"}]' "$1" "$2" "$1"
}

echo "[1] UNKNOWN on the first read, BEHIND on re-query → the PR IS updated (fails against the pre-#723 code)"
out=$(run_case "$(armed 1450 UNKNOWN)" 'echo BEHIND') || true
if grep -qx "1450" "$work/updated"; then note "PR #1450 was updated after the retry resolved UNKNOWN → BEHIND"; else
  bad "PR #1450 never updated — the retry did not happen (output: $out)"
fi
if grep -qx "1450" "$work/viewcalls"; then note "re-queried #1450 rather than trusting the first UNKNOWN"; else
  bad "no gh pr view re-query was issued for #1450"
fi

echo "[2] UNKNOWN that never resolves → skipped, but logged BY NUMBER and counted, not silently dropped"
out=$(run_case "$(armed 1459 UNKNOWN)" 'echo UNKNOWN') || true
if grep -q "1459" <<<"$out" && grep -q "::warning::" <<<"$out"; then note "still-UNKNOWN #1459 warned by number"; else
  bad "unresolved UNKNOWN was not warned by number (output: $out)"
fi
if grep -q "1 still UNKNOWN after retries" <<<"$out"; then note "terminal message distinguishes a no-op from a genuinely empty set"; else
  bad "terminal message did not report the still-UNKNOWN count (output: $out)"
fi
if [ -s "$work/updated" ]; then bad "an unresolved-UNKNOWN PR was updated anyway"; else note "unresolved PR left alone"; fi

echo "[3] a genuinely CLEAN PR is not re-queried and not updated"
out=$(run_case "$(armed 1400 CLEAN)" 'echo BEHIND') || true
if [ -s "$work/viewcalls" ]; then bad "re-queried a PR whose status was already resolved"; else note "no wasted re-query on a resolved status"; fi
if [ -s "$work/updated" ]; then bad "updated a CLEAN PR"; else note "CLEAN PR left alone"; fi
if grep -q "1 open PR(s) considered, 0 still UNKNOWN" <<<"$out"; then note "reports considered-count on the empty path"; else
  bad "terminal message missing the considered-count (output: $out)"
fi

echo "[4] a held PR is never re-queried — the hold must not be spent on API calls either"
out=$(run_case '[{"number":1401,"mergeStateStatus":"UNKNOWN","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"labels":[{"name":"hold"}],"headRefName":"feat/1401"}]' 'echo BEHIND') || true
if [ -s "$work/viewcalls" ]; then bad "re-queried a held PR"; else note "held PR excluded from the retry set"; fi
if [ -s "$work/updated" ]; then bad "updated a held PR"; else note "held PR left alone"; fi

echo "[5] an unarmed PR is never re-queried"
out=$(run_case '[{"number":1402,"mergeStateStatus":"UNKNOWN","isDraft":false,"autoMergeRequest":null,"labels":[],"headRefName":"feat/1402"}]' 'echo BEHIND') || true
if [ -s "$work/viewcalls" ]; then bad "re-queried a PR with auto-merge not armed"; else note "unarmed PR excluded from the retry set"; fi

if [ "$fail" -ne 0 ]; then echo "FAILED" >&2; exit 1; fi
echo "PASS: pr-auto-update lazy-mergeStateStatus retry (#723)"
