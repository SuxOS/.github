#!/usr/bin/env bash
#
# Unit-tests issue-build.yml's `build` job disposition dropped/superseded close path (#465).
#
# A `dropped` entry with `superseded: true` must `gh issue close --reason "not planned"`
# (stops it being re-claimed and re-dropped by every future builder run forever); an
# ordinary dropped entry (superseded absent/false) must instead just release the `building`
# label and post a "dropped from this batch" comment, leaving the issue open for retry. This
# was verified by hand during #465's build (extract the run: block with yq, fake gh/git shim,
# bash -e -c) but had no test-*.sh wired into self-check.yml, so a later refactor of the
# built/dropped overlap logic right above this loop (#468, #481) could silently break the
# close path with no CI signal (SuxOS/.github#495).
#
# Extracts the ACTUAL shell block shipped in the workflow (no hand-copied stand-in — same
# principle as test-scaffold-caller-regression.sh / test-pr-drain-dirty-collision.sh) and
# drives it with fixture disposition.json files via exported `gh`/`git` shell functions,
# asserting the close-vs-comment split and that `git`/`gh` are never hit for real.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq not on PATH" >&2; exit 1; }

wf=".github/workflows/issue-build.yml"
push_run="$(yq -r '.jobs.build.steps[] | select(.name == "Push and open ONE PR, or release claims on failure") | .run' "$wf")"

if ! printf '%s' "$push_run" | grep -q 'Closed as superseded/redundant'; then
  echo "FAIL: could not extract issue-build.yml's push/disposition script (anchors moved?)" >&2
  exit 1
fi

# $1 = scenario name, $2 = ISSUE_NUMBERS_JSON, $3 = disposition.json body, $4 = log path
# (truncated first). Runs the real extracted script with git/gh shimmed to no-ops that
# just record what they were called with.
run_scenario() {
  local numbers_json="$2" disposition="$3" log="$4"
  : > "$log"
  local dfile
  dfile="$(mktemp)"
  printf '%s' "$disposition" > "$dfile"

  # shellcheck disable=SC2317  # invoked indirectly via exported function
  git() {
    case "$1" in
      log) echo "fake-commit-line" ;;   # non-empty -> "commit ahead of base", never a real repo op
      push) return 0 ;;
      *) return 0 ;;
    esac
  }
  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() { echo "GH $*" >>"$LOG"; return 0; }
  export -f git gh

  ISSUE_NUMBERS_JSON="$numbers_json" RUN_URL="https://example.test/run/1" BASE_BRANCH="main" \
    BRANCH="bot/issue-build-test" TIER="high" GITHUB_REPOSITORY="test/repo" GH_TOKEN="x" \
    DISPOSITION_FILE="$dfile" LOG="$log" \
    bash -e -c "$push_run" >/dev/null 2>&1

  rm -f "$dfile"
}

echo "[1/3] plain dropped (superseded absent/false) -> release claim + 'dropped from batch' comment, no close"
log1="$(mktemp)"
run_scenario "plain-dropped" '[1,2]' \
  '{"built":[1],"dropped":[{"number":2,"reason":"too risky this session","superseded":false}]}' "$log1"
if grep -q 'GH issue edit 2 --repo test/repo --remove-label building' "$log1" \
  && grep -q 'GH issue comment 2 --repo test/repo --body 🤖 Dropped from this batch (not shipped in this PR): too risky this session' "$log1" \
  && ! grep -q 'GH issue close 2' "$log1"; then
  note "plain dropped #2: claim released + comment posted, not closed"
else
  bad "plain dropped #2: expected release+comment, not close — got: $(cat "$log1")"
fi
rm -f "$log1"

echo "[2/3] superseded dropped (superseded=true) -> release claim + close --reason 'not planned', no plain comment"
log2="$(mktemp)"
run_scenario "superseded-dropped" '[1,3]' \
  '{"built":[1],"dropped":[{"number":3,"reason":"already fixed by #999","superseded":true}]}' "$log2"
if grep -q 'GH issue edit 3 --repo test/repo --remove-label building' "$log2" \
  && grep -q -- 'GH issue close 3 --repo test/repo --reason not planned --comment 🤖 Closed as superseded/redundant (not shipped in this PR): already fixed by #999' "$log2" \
  && ! grep -q 'GH issue comment 3 --repo test/repo --body 🤖 Dropped from this batch' "$log2"; then
  note "superseded dropped #3: claim released + closed not-planned, no plain drop comment"
else
  bad "superseded dropped #3: expected release+close, no plain comment — got: $(cat "$log2")"
fi
rm -f "$log2"

echo "[3/3] mixed batch: one plain-dropped + one superseded-dropped + one built -> each takes its own path, built one only gets Closes"
log3="$(mktemp)"
run_scenario "mixed" '[1,2,3]' \
  '{"built":[1],"dropped":[{"number":2,"reason":"deferred","superseded":false},{"number":3,"reason":"stale, fixed elsewhere","superseded":true}]}' "$log3"
if grep -q 'GH issue comment 2 --repo test/repo --body 🤖 Dropped from this batch' "$log3" \
  && grep -q -- 'GH issue close 3 --repo test/repo --reason not planned' "$log3" \
  && grep -q 'GH pr create --repo test/repo --base main --head bot/issue-build-test --title build: drain high-priority backlog (1 issues) --body' "$log3" \
  && grep -q 'Closes #1' "$log3" \
  && ! grep -q 'Closes #2' "$log3" \
  && ! grep -q 'Closes #3' "$log3"; then
  note "mixed batch: #2 dropped-commented, #3 dropped-closed, PR body Closes only #1"
else
  bad "mixed batch: expected #2 comment / #3 close / Closes only #1 — got: $(cat "$log3")"
fi
rm -f "$log3"

if [ "$fail" -eq 0 ]; then
  echo "All issue-build disposition dropped/superseded close-path tests passed."
else
  echo "issue-build disposition dropped/superseded close-path tests FAILED." >&2
fi
exit "$fail"
