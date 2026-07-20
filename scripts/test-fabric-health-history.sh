#!/usr/bin/env bash
# Regression guard for fabric-health.yml's "Multi-day backlog history (streak + growth
# rate, #554)" step (id: history) — docs/design/2026-07-19-next-arc-decision-rule-design.md
# §3.2. This is the largest single piece of that design doc's slicing and had zero
# extraction-test coverage at the time it landed, same gap test-fabric-health-sweep.sh's
# header calls out for the sibling "collect" step. Covers: the streak correctly stops at
# the first zero-backlog gap OR the first non-zero day (whichever comes first, walking
# newest-first from today), the naive growth rate spans only the AVAILABLE (non-null)
# sampled days, days_available reports the degradation when a day has no successful run,
# and a per-repo streak/growth stays independent of an org-level gap on an UNRELATED day.
#
# Extracts the ACTUAL shipped step (no hand-copied stand-in — same principle as
# test-fabric-health-sweep.sh) and drives it with a fake `gh` keyed by --created date and
# run id, run via bash -e -c (not bare bash -c) to reproduce the runner's real
# `bash --noprofile --norc -eo pipefail` semantics (#411).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

WF=.github/workflows/fabric-health.yml
history_run=$(yq -r '.jobs.spine.steps[] | select(.id == "history") | .run' "$WF")

if ! printf '%s' "$history_run" | grep -q 'def streak_zero'; then
  echo "FAIL: could not extract the history step (anchors moved?)" >&2
  exit 1
fi

# Builds a fake `gh` that answers `run list --created <date> ... --json databaseId` with a
# fixed databaseId per date (from the caller's $1=date->id pairs, "date:id date:id ..."),
# and `run download <id> ... --dir DIR` by copying fixtures/<id>.json into DIR.
# $1 = shim dir, $2 = "date:id ..." map, $3 = fixtures dir (files named <id>.json)
make_fakegh() {
  local dir="$1" datemap="$2" fixdir="$3"
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$dir/calls.log"
if [ "\$1" = "run" ] && [ "\$2" = "list" ]; then
  created="" prev=""
  for a in "\$@"; do [ "\$prev" = "--created" ] && created="\$a"; prev="\$a"; done
  case " $datemap " in
    *" \$created:"*)
      id=\$(printf '%s\n' $datemap | tr ' ' '\n' | grep "^\$created:" | cut -d: -f2)
      echo "[{\"databaseId\": \$id}]"
      ;;
    *) echo '[]' ;;
  esac
elif [ "\$1" = "run" ] && [ "\$2" = "download" ]; then
  id="\$3" dir="" prev=""
  for a in "\$@"; do [ "\$prev" = "--dir" ] && dir="\$a"; prev="\$a"; done
  if [ -f "$fixdir/\$id.json" ]; then cp "$fixdir/\$id.json" "\$dir/fabric-status.json"; else exit 1; fi
else
  echo '[]'
fi
EOF
  chmod +x "$dir/gh"
}

# Runs the extracted history step against fixture `today.json` (the live snapshot already
# on disk from the "collect" step, in real usage) plus the fake gh's dated fixtures.
run_history() {
  local fakegh_dir="$1" today_fixture="$2" history_days="$3" repos="$4"
  local scratch status_json rc
  scratch=$(mktemp -d)
  cp "$today_fixture" "$scratch/fabric-status.json"
  ( cd "$scratch" && PATH="$fakegh_dir:$PATH" GH_TOKEN=x GITHUB_REPOSITORY=SuxOS/.github \
      HISTORY_DAYS="$history_days" REPOS="$repos" \
      bash -e -c "$history_run" ) > "$scratch/log" 2>&1
  rc=$?
  status_json=""
  [ -f "$scratch/fabric-status.json" ] && status_json=$(cat "$scratch/fabric-status.json")
  echo "$rc|$status_json|$scratch"
}

hfield() { printf '%s' "$2" | jq -r ".history$1"; }

day() { date -u -d "-$1 days" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d; }

today_zero='{"backlog_total":0,"backlog_zero":1,"repos":[{"repo":"sux","backlog":0,"collection":{"issues":1}},{"repo":"suxlib","backlog":0,"collection":{"issues":1}}]}'
today_nonzero='{"backlog_total":4,"backlog_zero":0,"repos":[{"repo":"sux","backlog":4,"collection":{"issues":1}},{"repo":"suxlib","backlog":0,"collection":{"issues":1}}]}'
d1zero='{"backlog_total":0,"backlog_zero":1,"repos":[{"repo":"sux","backlog":0,"collection":{"issues":1}},{"repo":"suxlib","backlog":0,"collection":{"issues":1}}]}'
d2zero='{"backlog_total":0,"backlog_zero":1,"repos":[{"repo":"sux","backlog":0,"collection":{"issues":1}},{"repo":"suxlib","backlog":0,"collection":{"issues":1}}]}'
d3nonzero='{"backlog_total":2,"backlog_zero":0,"repos":[{"repo":"sux","backlog":2,"collection":{"issues":1}},{"repo":"suxlib","backlog":0,"collection":{"issues":1}}]}'

echo "[1/4] streak stops at the first non-zero day, growth spans only available (non-null) days, days_available reports the gap"
d1=$(mktemp -d); f1=$(mktemp -d)
printf '%s' "$today_zero" > "$f1/101.json"
printf '%s' "$d1zero" > "$f1/102.json"
printf '%s' "$d2zero" > "$f1/103.json"
printf '%s' "$d3nonzero" > "$f1/104.json"
today_file=$(mktemp); printf '%s' "$today_zero" > "$today_file"
make_fakegh "$d1" "$(day 1):102 $(day 2):103 $(day 3):104" "$f1"
result=$(run_history "$d1" "$today_file" 7 "sux suxlib")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
if [ "$rc" -eq 0 ] && [ "$(hfield .backlog_zero_streak_days "$status_json")" = "3" ] \
    && [ "$(hfield .days_requested "$status_json")" = "7" ] \
    && [ "$(hfield .days_available "$status_json")" = "3" ]; then
  note "streak=3 (today+d1+d2 zero, d3 breaks it), days_available=3/7 (growth=$(hfield .backlog_growth_per_day "$status_json"))"
else
  bad "expected streak=3 days_available=3/7 (rc=$rc, history=$(printf '%s' "$status_json" | jq -c .history))"
fi
rm -rf "$d1" "$f1" "$scratch" "$today_file"

echo "[2/4] today itself already non-zero -> streak 0 regardless of prior days"
d2=$(mktemp -d); f2=$(mktemp -d)
printf '%s' "$d1zero" > "$f2/201.json"
today_file=$(mktemp); printf '%s' "$today_nonzero" > "$today_file"
make_fakegh "$d2" "$(day 1):201" "$f2"
result=$(run_history "$d2" "$today_file" 3 "sux suxlib")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
if [ "$rc" -eq 0 ] && [ "$(hfield .backlog_zero_streak_days "$status_json")" = "0" ]; then
  note "streak=0 when today's own backlog is non-zero"
else
  bad "expected streak=0 (rc=$rc, history=$(printf '%s' "$status_json" | jq -c .history))"
fi
rm -rf "$d2" "$f2" "$scratch" "$today_file"

echo "[3/4] no successful run any sampled day (total gap) -> streak/growth degrade to null-safe zero, no crash"
d3=$(mktemp -d); f3=$(mktemp -d)
today_file=$(mktemp); printf '%s' "$today_zero" > "$today_file"
make_fakegh "$d3" "" "$f3"
result=$(run_history "$d3" "$today_file" 4 "sux suxlib")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
if [ "$rc" -eq 0 ] && [ "$(hfield .days_available "$status_json")" = "0" ] \
    && [ "$(hfield .backlog_growth_per_day "$status_json")" = "null" ]; then
  note "days_available=0/4, growth=null (only today observed, fewer than 2 points)"
else
  bad "expected days_available=0 growth=null (rc=$rc, history=$(printf '%s' "$status_json" | jq -c .history))"
fi
rm -rf "$d3" "$f3" "$scratch" "$today_file"

echo "[4/4] a repo absent from an older day's repos[] (added to \$REPOS later) breaks only THAT repo's streak, not the org-wide one"
d4=$(mktemp -d); f4=$(mktemp -d)
d1_missing_suxlib='{"backlog_total":0,"backlog_zero":1,"repos":[{"repo":"sux","backlog":0,"collection":{"issues":1}}]}'
printf '%s' "$d1_missing_suxlib" > "$f4/401.json"
today_file=$(mktemp); printf '%s' "$today_zero" > "$today_file"
make_fakegh "$d4" "$(day 1):401" "$f4"
result=$(run_history "$d4" "$today_file" 2 "sux suxlib")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
org_streak=$(hfield .backlog_zero_streak_days "$status_json")
suxlib_streak=$(printf '%s' "$status_json" | jq -r '.history.repos.suxlib.backlog_zero_streak_days')
if [ "$rc" -eq 0 ] && [ "$org_streak" = "2" ] && [ "$suxlib_streak" = "1" ]; then
  note "org streak=2 (unaffected), suxlib streak=1 (breaks where it drops out of \$REPOS' historical repos[])"
else
  bad "expected org streak=2, suxlib streak=1 (rc=$rc, got org=$org_streak suxlib=$suxlib_streak)"
fi
rm -rf "$d4" "$f4" "$scratch" "$today_file"

if [ "$fail" -eq 0 ]; then
  echo "fabric-health history regression guard: PASS"
else
  echo "fabric-health history regression guard: FAIL"
fi
exit "$fail"
