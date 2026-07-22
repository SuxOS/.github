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

# The extracted script shells out to the shared marker-cycle-read/upsert helpers (#589) via
# .suxos-ci/.github/actions/... (a real run checks that repo out to that path separately —
# see issue-build.yml's "Checkout SuxOS/.github (shared marker-cycle helper)" step). This
# test only has this repo itself checked out, and it already IS SuxOS/.github, so a
# self-referential symlink resolves the same real, unmodified scripts with no drift.
[ -e .suxos-ci ] || ln -s . .suxos-ci
trap '[ -L .suxos-ci ] && rm -f .suxos-ci' EXIT

wf=".github/workflows/issue-build.yml"
push_run="$(yq -r '.jobs.build.steps[] | select(.name == "Push and open ONE PR, or release claims on failure") | .run' "$wf")"

if ! printf '%s' "$push_run" | grep -q 'Closed as superseded/redundant'; then
  echo "FAIL: could not extract issue-build.yml's push/disposition script (anchors moved?)" >&2
  exit 1
fi

# $1 = scenario name, $2 = ISSUE_NUMBERS_JSON, $3 = disposition.json body, $4 = log path
# (truncated first), $5 = optional prior `gh api .../comments --paginate` JSON response (the
# #562 drop-cycle marker read-back — default '[]', no prior marker). Runs the real extracted
# script with git/gh shimmed to no-ops that just record what they were called with.
run_scenario() {
  local numbers_json="$2" disposition="$3" log="$4" prior_comments="${5:-[]}"
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
  gh() {
    echo "GH $*" >>"$LOG"
    # The #562 drop-cycle marker read-back: `gh api repos/OWNER/REPO/issues/N/comments
    # --paginate` (listing) vs. `gh api repos/OWNER/REPO/issues/comments/ID -X PATCH` (update)
    # share the "api" verb but only the listing call's path ends in literal "/comments".
    if [ "$1" = "api" ]; then
      case "$2" in
        */comments) printf '%s' "$PRIOR_COMMENTS_JSON" ;;
      esac
    fi
    return 0
  }
  export -f git gh

  ISSUE_NUMBERS_JSON="$numbers_json" RUN_URL="https://example.test/run/1" BASE_BRANCH="main" \
    BRANCH="bot/issue-build-test" TIER="high" GITHUB_REPOSITORY="test/repo" GH_TOKEN="x" \
    DISPOSITION_FILE="$dfile" LOG="$log" PRIOR_COMMENTS_JSON="$prior_comments" \
    bash -e -c "$push_run" >/dev/null 2>&1

  rm -f "$dfile"
}

echo "[1/6] plain dropped (superseded absent/false) -> release claim + marker+'dropped from batch' comment, no close"
log1="$(mktemp)"
run_scenario "plain-dropped" '[1,2]' \
  '{"built":[1],"dropped":[{"number":2,"reason":"too risky this session","superseded":false}]}' "$log1"
if grep -q 'GH issue edit 2 --repo test/repo --remove-label building' "$log1" \
  && grep -q -- 'GH api repos/test/repo/issues/2/comments -f body=<!-- issue-build:drop cycle=1' "$log1" \
  && grep -q '🤖 Dropped from this batch (not shipped in this PR): too risky this session' "$log1" \
  && ! grep -q 'GH issue close 2' "$log1" \
  && ! grep -q 'GH issue edit 2 --repo test/repo --add-label needs-human' "$log1"; then
  note "plain dropped #2: claim released + marker+comment posted (cycle=1, no escalation), not closed"
else
  bad "plain dropped #2: expected release+marker+comment, not close — got: $(cat "$log1")"
fi
rm -f "$log1"

echo "[2/6] superseded dropped (superseded=true) -> release claim + close --reason 'not planned', no plain comment, no marker read"
log2="$(mktemp)"
run_scenario "superseded-dropped" '[1,3]' \
  '{"built":[1],"dropped":[{"number":3,"reason":"already fixed by #999","superseded":true}]}' "$log2"
if grep -q 'GH issue edit 3 --repo test/repo --remove-label building' "$log2" \
  && grep -q -- 'GH issue close 3 --repo test/repo --reason not planned --comment 🤖 Closed as superseded/redundant (not shipped in this PR): already fixed by #999' "$log2" \
  && ! grep -q 'GH issue comment 3 --repo test/repo --body' "$log2" \
  && ! grep -q 'GH api repos/test/repo/issues/3/comments' "$log2"; then
  note "superseded dropped #3: claim released + closed not-planned, no plain comment, no drop-cycle marker read (closed issues can't re-cycle)"
else
  bad "superseded dropped #3: expected release+close, no plain comment, no marker read — got: $(cat "$log2")"
fi
rm -f "$log2"

echo "[3/6] mixed batch: one plain-dropped + one superseded-dropped + one built -> each takes its own path, built one only gets Closes"
log3="$(mktemp)"
run_scenario "mixed" '[1,2,3]' \
  '{"built":[1],"dropped":[{"number":2,"reason":"deferred","superseded":false},{"number":3,"reason":"stale, fixed elsewhere","superseded":true}]}' "$log3"
if grep -q -- 'GH api repos/test/repo/issues/2/comments -f body=<!-- issue-build:drop cycle=1' "$log3" \
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

echo "[4/6] (#562) escalation ladder: first drop -> cycle=1 marker posted as a NEW comment, no needs-human escalation yet"
log4="$(mktemp)"
run_scenario "first-drop-cycle1" '[4]' \
  '{"built":[],"dropped":[{"number":4,"reason":"too large this session","superseded":false}]}' "$log4"
if grep -q 'GH api repos/test/repo/issues/4/comments --paginate' "$log4" \
  && grep -q -- 'GH api repos/test/repo/issues/4/comments -f body=<!-- issue-build:drop cycle=1' "$log4" \
  && grep -q '🤖 Dropped from this batch (not shipped in this PR): too large this session' "$log4" \
  && ! grep -q 'GH issue edit 4 --repo test/repo --add-label needs-human' "$log4" \
  && ! grep -q 'PATCH' "$log4"; then
  note "first drop of #4: marker cycle=1 posted as new comment, no escalation"
else
  bad "first drop of #4: expected cycle=1 new-comment marker, no escalation — got: $(cat "$log4")"
fi
rm -f "$log4"

echo "[5/6] (#562) escalation ladder: second drop with a prior cycle=1 marker -> cycle=2 hits the threshold, needs-human applied, marker PATCHed in place"
log5="$(mktemp)"
prior='[{"id":777,"body":"<!-- issue-build:drop cycle=1 at=2026-07-18T00:00:00Z -->\n🤖 Dropped from this batch (not shipped in this PR): first attempt too risky."}]'
run_scenario "second-drop-cycle2" '[5]' \
  '{"built":[],"dropped":[{"number":5,"reason":"still too large","superseded":false}]}' "$log5" "$prior"
if grep -q 'GH issue edit 5 --repo test/repo --add-label needs-human' "$log5" \
  && grep -q -- 'GH api repos/test/repo/issues/comments/777 -X PATCH -f body=<!-- issue-build:drop cycle=2' "$log5" \
  && grep -q 'Dropped from this batch for cycle 2' "$log5" \
  && grep -q 'needs-human' "$log5" \
  && ! grep -q -- 'GH api repos/test/repo/issues/5/comments -f body=<!-- issue-build:drop' "$log5"; then
  note "second drop of #5: cycle=2 escalates (needs-human applied, marker PATCHed in place, not posted as a new comment)"
else
  bad "second drop of #5: expected cycle=2 escalation (needs-human + PATCH) — got: $(cat "$log5")"
fi
rm -f "$log5"

echo "[6/6] (#679) partial: a multi-item issue with some but not all asks shipped -> claim released + summary comment, not closed, no Closes #n"
log6="$(mktemp)"
run_scenario "partial" '[6,7]' \
  '{"built":[7],"partial":[{"number":6,"shipped":"items 1-4","remaining":"items 5-6","reason":"ran out of turns this session"}]}' "$log6"
if grep -q 'GH issue edit 6 --repo test/repo --remove-label building' "$log6" \
  && grep -q '🤖 Partially shipped in this batch (not auto-closed): shipped — items 1-4; remaining — items 5-6 (ran out of turns this session)' "$log6" \
  && grep -q 'Closes #7' "$log6" \
  && ! grep -q 'Closes #6' "$log6" \
  && ! grep -q 'GH issue close 6' "$log6" \
  && ! grep -q -- 'GH api repos/test/repo/issues/6/comments -f body=<!-- issue-build:drop' "$log6"; then
  note "partial #6: claim released + shipped/remaining summary comment, not closed, only #7 gets Closes"
else
  bad "partial #6: expected release+summary comment, no close, no Closes #6 — got: $(cat "$log6")"
fi
rm -f "$log6"

if [ "$fail" -eq 0 ]; then
  echo "All issue-build disposition dropped/superseded close-path tests passed."
else
  echo "issue-build disposition dropped/superseded close-path tests FAILED." >&2
fi
exit "$fail"
