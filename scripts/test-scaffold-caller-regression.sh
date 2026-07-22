#!/usr/bin/env bash
# Regression guard for audit-confirmed cross-repo pipeline defects.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

# Extract a composite action step's `run:` shell block by step id, so these
# tests exercise the actual shipped logic instead of a hand-copied stand-in
# that can drift from it.
extract_run() {
  yq -r ".runs.steps[] | select(.id == \"$2\") | .run" "$1"
}

echo "[1/5] scaffold-caller.sh's security-review template includes ready_for_review"
# (The HIGH_BLAST_RE high-blast/trusted-author no-verdict classification this
# check used to test was removed from security-review.yml: a missing verdict
# is now an unconditional advisory pass, never a fail-closed `hold`, regardless
# of what the diff touches — see the "Gate — advisory pass on missing verdict"
# step's comment for why.)
stub=$(awk '/^emit security-review <<YAML/,/^YAML$/' scripts/scaffold-caller.sh)
if printf '%s\n' "$stub" | grep -q 'ready_for_review'; then
  note "generated security-review stub includes ready_for_review"
else
  bad "scaffold-caller.sh's security-review template omits ready_for_review — a newly-scaffolded repo's required security gate will silently never re-run when a draft PR goes ready (GitHub counts a skipped required check as passing)"
fi

# Dependabot dep-bump PRs get NO secrets on `pull_request`, so the required review fails closed
# forever (#621/#622). The template must trigger on pull_request_target (secrets present) AND
# route ONLY dependabot[bot] there (the job `if`) AND allow the dependabot[bot] actor — dropping
# any one silently re-breaks dep-bump merges. (Behavioral routing matrix lives in
# scripts/test-security-review-dependabot-routing.sh, which drives BOTH this template and the
# checked-in self-security-review.yml stub; this is the coarse "template didn't lose it" guard.)
if printf '%s\n' "$stub" | grep -q 'pull_request_target'; then
  note "generated security-review stub triggers on pull_request_target (Dependabot secrets path)"
else
  bad "scaffold-caller.sh's security-review template omits pull_request_target — Dependabot dep-bump PRs get no secrets on plain pull_request, so the required review fails closed forever (#621/#622)"
fi
if printf '%s\n' "$stub" | grep -q "user.login != 'dependabot\[bot\]'" \
   && printf '%s\n' "$stub" | grep -q "user.login == 'dependabot\[bot\]'"; then
  note "generated security-review stub routes each PR to exactly one trigger by the dependabot[bot] actor"
else
  bad "scaffold-caller.sh's security-review template lost the dependabot[bot] routing 'if' — the review would double-run or a human PR could reach the privileged pull_request_target context"
fi
if printf '%s\n' "$stub" | grep -q 'allowed-bots: "suxbot\[bot\],dependabot\[bot\]"'; then
  note "generated security-review stub allows the dependabot[bot] actor"
else
  bad "scaffold-caller.sh's security-review template must list dependabot[bot] in allowed-bots or claude-code-action refuses the bot PR and hard-fails the required gate"
fi

echo "[2/5] pr-eligibility's auto-merge safety regex fixture matrix (#229)"
pr_eligibility_run=$(extract_run .github/actions/pr-eligibility/action.yml evaluate)
check_pr_eligibility() {
  local desc="$1" prs_json="$2" expect="$3" out
  local outfile=/tmp/pr-eligibility-out.$$
  : > "$outfile"
  PRS_JSON="$prs_json" GITHUB_OUTPUT="$outfile" bash -e -c "$pr_eligibility_run" >/dev/null 2>&1 || true
  out=$(grep '^eligible-numbers=' "$outfile" | cut -d= -f2-)
  rm -f "$outfile"
  if [ "$out" = "$expect" ]; then
    note "$desc -> eligible-numbers='${expect:-<none>}'"
  else
    bad "$desc: expected eligible-numbers='$expect', got '$out'"
  fi
}
check_pr_eligibility "safe-type title, no label" '[{"number":1,"title":"fix: foo","labels":[]}]' "1"
check_pr_eligibility "safe-type + breaking bang, automerge label" '[{"number":2,"title":"fix!: foo","labels":["automerge"]}]' ""
check_pr_eligibility "label-only eligibility with a breaking title" '[{"number":3,"title":"feat!: foo","labels":["automerge"]}]' ""
check_pr_eligibility "mixed-case conventional type" '[{"number":4,"title":"FIX: foo","labels":[]}]' "4"
check_pr_eligibility "non-matching title, no label" '[{"number":5,"title":"wip: nonsense","labels":[]}]' ""
# Guards against the #404 bug class under the harness's real `bash -e -c`: an
# empty PRS_JSON drives the jq pipeline's `.[]` generator to zero iterations,
# a no-match/empty-result shape that must produce eligible-numbers="" rather
# than aborting the step (#411).
check_pr_eligibility "empty PR list (no-match/empty-result)" '[]' ""

echo "[3/5] upsert-tracking-issue list/match fixtures (#228)"
upsert_run=$(extract_run .github/actions/upsert-tracking-issue/action.yml upsert)
run_upsert() {
  local fakegh_dir="$1" list_limit="$2" out_file="$3"
  : > "$out_file"
  PATH="$fakegh_dir:$PATH" GITHUB_OUTPUT="$out_file" \
    REPO=test/repo TITLE="Tracking Issue" BODY="body" MODE=close \
    UPDATE_MODE=comment LIST_LIMIT="$list_limit" LABELS="" \
    bash -e -c "$upsert_run"
}

# 3a: exhaustive lookup finds a title match past the first (bounded) page.
d1=$(mktemp -d)
cat > "$d1/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    limit=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "--limit" ] && limit="${args[$((i + 1))]}"
    done
    if [ "$limit" = "2" ]; then
      echo '[{"number":10,"title":"Other A"},{"number":11,"title":"Other B"}]'
    else
      echo '[{"number":12,"title":"Other C"},{"number":20,"title":"Tracking Issue"},{"number":13,"title":"Other D"}]'
    fi
    ;;
  "issue comment" | "issue close") exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$d1/gh"
out1=/tmp/upsert-out-1.$$
rc=0
run_upsert "$d1" 2 "$out1" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^issue-number=20$' "$out1"; then
  note "exhaustive lookup finds a title match past the first (limit=2) page"
else
  bad "exhaustive lookup failed to find a title match past the first page (rc=$rc, output: $(cat "$out1" 2>/dev/null))"
fi
rm -rf "$d1" "$out1"

# 3b: a gh error during list surfaces as a hard failure, not a silent skip.
d2=$(mktemp -d)
cat > "$d2/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$d2/gh"
out2=/tmp/upsert-out-2.$$
rc=0
err=$(run_upsert "$d2" 2 "$out2" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q '::error::gh issue list failed'; then
  note "a gh issue list failure surfaces as ::error:: and a non-zero exit"
else
  bad "a gh issue list failure did not surface as expected (rc=$rc, output: $err)"
fi
rm -rf "$d2" "$out2"

# 3c: duplicate-title matches resolve to the documented first-match, not an error.
d3=$(mktemp -d)
cat > "$d3/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") echo '[{"number":30,"title":"Tracking Issue"},{"number":31,"title":"Tracking Issue"}]' ;;
  "issue comment" | "issue close") exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$d3/gh"
out3=/tmp/upsert-out-3.$$
rc=0
run_upsert "$d3" 2 "$out3" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^issue-number=30$' "$out3"; then
  note "duplicate-title matches resolve to the first match (#30), not an error"
else
  bad "duplicate-title matches did not resolve to the documented first-match (rc=$rc, output: $(cat "$out3" 2>/dev/null))"
fi
rm -rf "$d3" "$out3"

echo "[4/5] flood-guard / check-throttle fail-open behavior (#230)"
flood_guard_run=$(extract_run .github/actions/flood-guard/action.yml check)
check_throttle_run=$(extract_run .github/actions/check-throttle/action.yml check)

# 4a: flood-guard fails open (features_ok=true) when its two upstream "list
# open PRs" steps (nested gh-list-exhaustive composite actions, #396) fail or
# refuse via continue-on-error — which surfaces here as empty *_JSON.
out4=/tmp/flood-guard-out.$$
: > "$out4"
GITHUB_OUTPUT="$out4" THRESHOLD=8 APP_JSON="" AUTHOR_JSON="" bash -e -c "$flood_guard_run" >/dev/null 2>&1 || true
if grep -q '^features_ok=true$' "$out4"; then
  note "flood-guard fails open (features_ok=true) when APP_JSON/AUTHOR_JSON are empty (upstream lists failed/refused)"
else
  bad "flood-guard did not fail open on empty APP_JSON/AUTHOR_JSON (output: $(cat "$out4" 2>/dev/null))"
fi
rm -rf "$out4"

# 4a-2: the --app and --author queries return the SAME bot PRs (one GitHub
# App bot account has exactly one login), so overlapping results must be
# deduped by number, not summed (#399: summing double-counted every real bot
# PR and tripped the guard at roughly half its configured threshold).
out4b=/tmp/flood-guard-dedupe-out.$$
: > "$out4b"
GITHUB_OUTPUT="$out4b" THRESHOLD=8 \
  APP_JSON='[{"number":1},{"number":2},{"number":3}]' \
  AUTHOR_JSON='[{"number":1},{"number":2},{"number":3}]' \
  bash -e -c "$flood_guard_run" >/dev/null 2>&1 || true
if grep -q '^open_bot_prs=3$' "$out4b"; then
  note "flood-guard dedupes overlapping --app/--author results instead of summing them (#399)"
else
  bad "flood-guard did not dedupe overlapping --app/--author results (expected open_bot_prs=3, output: $(cat "$out4b" 2>/dev/null))"
fi
rm -rf "$out4b"

# 4b: check-throttle fails open (level=green, go=true) on gh error and on
# malformed tracking-issue bodies (missing level line, garbage suffix, wrong case).
run_check_throttle() {
  local body_json="$1" defer_at="$2" out_file="$3" fail_gh="${4:-}"
  local d; d=$(mktemp -d)
  if [ -n "$fail_gh" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$d/gh"
  else
    cat > "$d/gh" <<EOF
#!/usr/bin/env bash
echo '[{"title":"Autonomy throttle","body":$body_json}]'
EOF
  fi
  chmod +x "$d/gh"
  : > "$out_file"
  PATH="$d:$PATH" GITHUB_OUTPUT="$out_file" DEFER_AT="$defer_at" REPO=test/repo bash -e -c "$check_throttle_run" >/dev/null 2>&1 || true
  rm -rf "$d"
}
check_fail_open() {
  local desc="$1" body_json="$2" fail_gh="${3:-}"
  local out=/tmp/check-throttle-out.$$
  run_check_throttle "$body_json" red "$out" "$fail_gh"
  if grep -q '^level=green$' "$out" && grep -q '^go=true$' "$out"; then
    note "check-throttle fails open on: $desc"
  else
    bad "check-throttle did not fail open on: $desc (output: $(cat "$out" 2>/dev/null))"
  fi
  rm -f "$out"
}
check_fail_open "gh issue list error" '""' fail
check_fail_open "tracking issue body missing a level line" '"no level info here"'
check_fail_open "garbage suffix after level" '"level: red-ish\nmore text"'
check_fail_open "wrong-case level line" '"Level: RED"'

echo "[5/5] scaffold-caller.sh's emit() skips an existing .yaml stub, not just .yml (#568)"
tmpwf=$(mktemp -d)
printf 'name: Custom audit\non:\n  pull_request:\njobs:\n  audit:\n    runs-on: ubuntu-latest\n    steps: [{ run: "echo custom" }]\n' > "$tmpwf/audit.yaml"
bash scripts/scaffold-caller.sh --out-dir "$tmpwf" -w "" >/dev/null
if [ -f "$tmpwf/audit.yaml" ] && ! [ -e "$tmpwf/audit.yml" ] && grep -q 'Custom audit' "$tmpwf/audit.yaml"; then
  note "emit() skips writing audit.yml alongside an existing customized audit.yaml"
else
  bad "emit() did not skip an existing .yaml stub — a customized audit.yaml was shadowed/duplicated by a freshly-scaffolded audit.yml"
fi
rm -rf "$tmpwf"

[ "$fail" -eq 0 ] && { echo "scaffold-caller regression guard: PASS"; exit 0; } || { echo "scaffold-caller regression guard: FAIL"; exit 1; }
