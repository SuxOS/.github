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

echo "[1/4] scaffold-caller.sh's security-review template includes ready_for_review"
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

echo "[2/4] pr-eligibility's auto-merge safety regex fixture matrix (#229)"
pr_eligibility_run=$(extract_run .github/actions/pr-eligibility/action.yml evaluate)
check_pr_eligibility() {
  local desc="$1" prs_json="$2" expect="$3" out
  local outfile=/tmp/pr-eligibility-out.$$
  : > "$outfile"
  PRS_JSON="$prs_json" GITHUB_OUTPUT="$outfile" bash -c "$pr_eligibility_run" >/dev/null 2>&1 || true
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

echo "[3/4] upsert-tracking-issue list/match fixtures (#228)"
upsert_run=$(extract_run .github/actions/upsert-tracking-issue/action.yml upsert)
run_upsert() {
  local fakegh_dir="$1" list_limit="$2" out_file="$3"
  : > "$out_file"
  PATH="$fakegh_dir:$PATH" GITHUB_OUTPUT="$out_file" \
    REPO=test/repo TITLE="Tracking Issue" BODY="body" MODE=close \
    UPDATE_MODE=comment LIST_LIMIT="$list_limit" LABELS="" \
    bash -c "$upsert_run"
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

echo "[4/4] flood-guard / check-throttle fail-open behavior (#230)"
flood_guard_run=$(extract_run .github/actions/flood-guard/action.yml check)
check_throttle_run=$(extract_run .github/actions/check-throttle/action.yml check)

# 4a: flood-guard fails open (features_ok=true) when gh pr list errors out.
d4=$(mktemp -d)
cat > "$d4/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$d4/gh"
out4=/tmp/flood-guard-out.$$
: > "$out4"
PATH="$d4:$PATH" GITHUB_OUTPUT="$out4" THRESHOLD=8 REPO=test/repo bash -c "$flood_guard_run" >/dev/null 2>&1 || true
if grep -q '^features_ok=true$' "$out4"; then
  note "flood-guard fails open (features_ok=true) when gh pr list errors"
else
  bad "flood-guard did not fail open on a gh pr list error (output: $(cat "$out4" 2>/dev/null))"
fi
rm -rf "$d4" "$out4"

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
  PATH="$d:$PATH" GITHUB_OUTPUT="$out_file" DEFER_AT="$defer_at" REPO=test/repo bash -c "$check_throttle_run" >/dev/null 2>&1 || true
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

[ "$fail" -eq 0 ] && { echo "scaffold-caller regression guard: PASS"; exit 0; } || { echo "scaffold-caller regression guard: FAIL"; exit 1; }
