#!/usr/bin/env bash
# Unit-tests pr-drain.yml's DIRTY-CONFLICT sweep: the sibling hot-file-collision
# diagnostic (SuxOS/.github#437), the live-recheck candidate widening against a stale
# list snapshot (#484/#506), the `keep` opt-out (#528), the `building`-release regex
# covering issue-build's "Related to #n" wording (#509), and the stable-`mergeable`
# gate that replaced the flapping `mergeStateStatus == DIRTY` check (#570): only
# `mergeable == "CONFLICTING"` triggers close+requeue, while `MERGEABLE`
# (blocked-not-conflicting) and `UNKNOWN` (still computing) are left alone.
#
# Even with the requeue cap fixed (#434), issue-build.yml's `parallel-batches` default
# still allows 2 concurrently-open bot/issue-build-* PRs by design. If they happen to
# pick issues that both touch the same file, the second to merge goes DIRTY and this
# sweep recovers it (close + requeue) exactly as it always did — but until now that
# recovery gave no signal distinguishing "collided with a sibling builder PR" (the
# residual, wasted-build-spend failure mode #437 describes) from ordinary drift against
# main. The fix adds a best-effort note to the closing comment when the DIRTY PR's
# changed files (from the `files` field now included in the batch `gh pr list` call)
# overlap with another still-open bot/issue-build-* PR's changed files.
#
# Extracts the ACTUAL fan-out script shipped in the workflow (no hand-copied stand-in —
# same principle as test-scaffold-caller-regression.sh) and drives it with fixture
# PR lists via an exported `gh` shell function, asserting the note appears only when a
# real file overlap exists.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq not on PATH" >&2; exit 1; }

wf=".github/workflows/pr-drain.yml"
drain_run="$(yq -r '.jobs.drain.steps[] | select(.id == "drain") | .run' "$wf")"

if ! printf '%s' "$drain_run" | grep -q 'Hot-file collision'; then
  echo "FAIL: could not extract pr-drain drain script (anchors moved?)" >&2
  exit 1
fi

pr100='{"number":100,"title":"t100","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-100","files":[{"path":"CLAUDE.md"},{"path":"foo.txt"}]}'
pr200='{"number":200,"title":"t200","isDraft":false,"labels":[],"mergeStateStatus":"CLEAN","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-200","files":[{"path":"CLAUDE.md"},{"path":"bar.txt"}]}'
pr300='{"number":300,"title":"t300","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-300","files":[{"path":"onlymine.txt"}]}'
pr400='{"number":400,"title":"t400","isDraft":false,"labels":[],"mergeStateStatus":"UNKNOWN","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-400","files":[{"path":"onlymine.txt"}]}'
pr500='{"number":500,"title":"t500","isDraft":false,"labels":[{"name":"keep"}],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-500","files":[{"path":"onlymine.txt"}]}'
# Live-recheck fixtures gate on the stable `mergeable` enum (SuxOS/.github#570), not the
# flapping `mergeStateStatus`. `mergeStateStatus` is retained in these fixtures only to
# prove the gate no longer keys off it (see scenario [7], where it reads DIRTY yet the PR
# is left alone because `mergeable != CONFLICTING`).
view100='{"updatedAt":"2020-01-01T00:00:00Z","number":100,"body":"Closes #1","headRefName":"bot/issue-build-100","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"}'
view300='{"updatedAt":"2020-01-01T00:00:00Z","number":300,"body":"Closes #3","headRefName":"bot/issue-build-300","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"}'
view400='{"updatedAt":"2020-01-01T00:00:00Z","number":400,"body":"Closes #4","headRefName":"bot/issue-build-400","isDraft":false,"labels":[],"mergeStateStatus":"BLOCKED","mergeable":"CONFLICTING"}'
view500='{"updatedAt":"2020-01-01T00:00:00Z","number":500,"body":"Closes #5","headRefName":"bot/issue-build-500","isDraft":false,"labels":[{"name":"keep"}],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"}'
pr600='{"number":600,"title":"t600","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-600","files":[{"path":"onlymine.txt"}]}'
view600='{"updatedAt":"2020-01-01T00:00:00Z","number":600,"body":"Related to #7 (not auto-closed — no disposition record, please verify)\nRelated to #8 (not auto-closed — no disposition record, please verify)","headRefName":"bot/issue-build-600","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"}'
pr700='{"number":700,"title":"t700","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-700","files":[{"path":"onlymine.txt"}]}'
view700='{"updatedAt":"2020-01-01T00:00:00Z","number":700,"body":"This change is not related to #9. Related to #10 (not auto-closed — no disposition record, please verify)","headRefName":"bot/issue-build-700","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"}'
# #570 regression: a builder PR whose flapping `mergeStateStatus` reads DIRTY but whose
# stable `mergeable` is MERGEABLE (mergeable-but-BLOCKED on checks/auto-merge, NOT a real
# conflict) must be LEFT ALONE — the old gate would have wrongly closed it.
pr800='{"number":800,"title":"t800","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-800","files":[{"path":"onlymine.txt"}]}'
view800='{"updatedAt":"2020-01-01T00:00:00Z","number":800,"body":"Closes #11","headRefName":"bot/issue-build-800","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","mergeable":"MERGEABLE"}'
# #570: `mergeable == UNKNOWN` (GitHub still computing) must also be left alone — only a
# confirmed CONFLICTING read triggers close+requeue.
pr900='{"number":900,"title":"t900","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-900","files":[{"path":"onlymine.txt"}]}'
view900='{"updatedAt":"2020-01-01T00:00:00Z","number":900,"body":"Closes #12","headRefName":"bot/issue-build-900","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","mergeable":"UNKNOWN"}'
# SuxOS/.github#591: a CONFLICTING live re-check whose updatedAt is within the last 60s
# is deferred instead of acted on — the PR may be mid-force-push resolving its own
# conflict at the exact moment of this re-check.
pr1000='{"number":1000,"title":"t1000","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"2026-07-18T00:00:00Z","headRefName":"bot/issue-build-1000","files":[{"path":"onlymine.txt"}]}'
view1000_template='{"updatedAt":"__FRESH__","number":1000,"body":"Closes #13","headRefName":"bot/issue-build-1000","isDraft":false,"labels":[],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"}'

# $1 = scenario name, $2 = PRS_JSON array, $3 = dirty PR number, $4 = its `gh pr view` JSON,
# $5 = comments-log path (truncated first). Runs the real extracted script.
run_scenario() {
  local prs_json="$2" dirty_n="$3" view_json="$4" log="$5"
  : > "$log"

  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() {
    case "$1 $2" in
      "pr list") printf '%s' "$PRS_JSON" ;;
      "pr view")
        if [ "$3" = "$DIRTY_N" ]; then printf '%s' "$VIEW_JSON"; else return 1; fi
        ;;
      "pr comment") printf 'COMMENT %s: %s\n' "$3" "$5" >> "$LOG" ;;
      "pr close") return 0 ;;
      "issue edit") printf 'ISSUE_EDIT %s\n' "$3" >> "$LOG"; return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f gh
  PRS_JSON="$prs_json" DIRTY_N="$dirty_n" VIEW_JSON="$view_json" LOG="$log" \
    STALE_DAYS="14" PR_LIMIT="200" DRY_RUN="false" GH_REPO="test/repo" \
    bash -e -c "$drain_run" >/dev/null 2>&1
}

echo "[1/9] CONFLICTING PR sharing a file with an open sibling builder PR"
log1=$(mktemp)
run_scenario "collision" "[$pr100,$pr200]" "100" "$view100" "$log1"
if grep -q 'COMMENT 100:.*Hot-file collision with sibling builder PR(s): #200 on CLAUDE.md.*#437' "$log1"; then
  note "collision note names sibling #200 and the shared file (CLAUDE.md)"
else
  bad "expected a #200/CLAUDE.md collision note in the close comment, got: $(cat "$log1")"
fi
rm -f "$log1"

echo "[2/9] CONFLICTING PR with no file overlap against the same open sibling"
log2=$(mktemp)
run_scenario "no-collision" "[$pr300,$pr200]" "300" "$view300" "$log2"
if grep -q 'COMMENT 300:' "$log2" && ! grep -q 'Hot-file collision' "$log2"; then
  note "no collision note when files don't overlap"
else
  bad "expected a plain close comment with no collision note, got: $(cat "$log2")"
fi
rm -f "$log2"

echo "[3/9] list snapshot's stale/flapping mergeStateStatus is ignored; live re-check confirms mergeable==CONFLICTING (SuxOS/.github#484/#506/#570)"
log3=$(mktemp)
run_scenario "stale-snapshot" "[$pr400]" "400" "$view400" "$log3"
if grep -q 'COMMENT 400:' "$log3"; then
  note "PR closed on live re-check (mergeable==CONFLICTING) even though its mergeStateStatus read BLOCKED"
else
  bad "expected #400 to be closed via live re-check despite a stale/flapping mergeStateStatus, got: $(cat "$log3")"
fi
rm -f "$log3"

echo "[4/9] CONFLICTING builder PR labeled \`keep\` is left alone, same as \`hold\` (SuxOS/.github#528)"
log4=$(mktemp)
run_scenario "keep-label" "[$pr500]" "500" "$view500" "$log4"
if [ ! -s "$log4" ]; then
  note "keep-labeled DIRTY PR was not commented/closed"
else
  bad "expected #500 (keep-labeled) to be left alone, got: $(cat "$log4")"
fi
rm -f "$log4"

echo "[5/9] CONFLICTING builder PR linked only via 'Related to #n' still releases \`building\` (SuxOS/.github#509)"
log5=$(mktemp)
run_scenario "related-to-wording" "[$pr600]" "600" "$view600" "$log5"
if grep -q 'ISSUE_EDIT 7' "$log5" && grep -q 'ISSUE_EDIT 8' "$log5"; then
  note "building stripped from #7 and #8 via 'Related to #n' wording"
else
  bad "expected ISSUE_EDIT for #7 and #8, got: $(cat "$log5")"
fi
rm -f "$log5"

echo "[6/9] a negated 'not related to #n' does NOT release that issue's building claim (SuxOS/.github#538)"
log6=$(mktemp)
run_scenario "negated-related-to" "[$pr700]" "700" "$view700" "$log6"
if grep -q 'ISSUE_EDIT 10' "$log6" && ! grep -q 'ISSUE_EDIT 9' "$log6"; then
  note "building stripped from #10 but NOT from #9 (negated 'not related to #9')"
else
  bad "expected ISSUE_EDIT for #10 only (not #9), got: $(cat "$log6")"
fi
rm -f "$log6"

echo "[7/9] flapping mergeStateStatus==DIRTY but stable mergeable==MERGEABLE (blocked, not conflicting) is LEFT ALONE (SuxOS/.github#570)"
log7=$(mktemp)
run_scenario "mergeable-but-blocked" "[$pr800]" "800" "$view800" "$log7"
if [ ! -s "$log7" ]; then
  note "mergeable-but-blocked PR (mergeStateStatus DIRTY, mergeable MERGEABLE) was not commented/closed/requeued"
else
  bad "expected #800 (mergeable==MERGEABLE) to be left alone, got: $(cat "$log7")"
fi
rm -f "$log7"

echo "[8/9] mergeable==UNKNOWN (still computing) is LEFT ALONE — only CONFLICTING triggers close+requeue (SuxOS/.github#570)"
log8=$(mktemp)
run_scenario "mergeable-unknown" "[$pr900]" "900" "$view900" "$log8"
if [ ! -s "$log8" ]; then
  note "mergeable==UNKNOWN PR was not commented/closed/requeued"
else
  bad "expected #900 (mergeable==UNKNOWN) to be left alone, got: $(cat "$log8")"
fi
rm -f "$log8"

echo "[9/9] CONFLICTING PR updated <60s ago is deferred, not closed (SuxOS/.github#591)"
log9=$(mktemp)
view1000=$(printf '%s' "$view1000_template" | jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updatedAt = $now')
run_scenario "fresh-update" "[$pr1000]" "1000" "$view1000" "$log9"
if [ ! -s "$log9" ]; then
  note "freshly-updated CONFLICTING PR was deferred (not commented/closed)"
else
  bad "expected #1000 (updated <60s ago) to be deferred, got: $(cat "$log9")"
fi
rm -f "$log9"

if [ "$fail" -eq 0 ]; then
  echo "All pr-drain DIRTY-collision tests passed."
else
  echo "pr-drain DIRTY-collision tests FAILED." >&2
fi
exit "$fail"
