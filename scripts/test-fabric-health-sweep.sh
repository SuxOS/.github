#!/usr/bin/env bash
# Regression guard for fabric-health.yml's "Collect cross-repo health into
# fabric-status.json" step (id: collect) — specifically the workflow_red /
# collection.runs rollup (#421): a batch-window lookup by workflowDatabaseId,
# with a per-workflow `gh run list` fallback when a workflow's latest run
# falls outside the batched window, and cap-hit detection on the workflow
# list itself (#345/#381). Unlike scaffold-caller/pr-eligibility/etc, this
# logic had zero extraction-test coverage even though it already carried one
# bug (#415, fixed on a sibling branch, not landed here yet) — a future edit
# could reintroduce that or a similar conclusion-value bug with nothing to
# catch it.
#
# Deliberately does NOT assert on "timed_out" conclusions: that's #415's
# fix, tracked/landing separately, and asserting either its presence or
# absence here would just make this test order-dependent on merge order.
# This covers the batch/fallback/cap-hit machinery, which is orthogonal to
# which conclusion values count as red.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

WF=.github/workflows/fabric-health.yml
collect_run=$(yq -r '.jobs.spine.steps[] | select(.id == "collect") | .run' "$WF")

# Builds a fake `gh` covering every call the "collect" step makes for a
# single-repo sweep: issue/pr lists (empty — out of scope here), the
# workflow list, the batch run list, and the per-workflow fallback lookup.
# $1 = dir to write the shim into
# $2 = workflow list JSON
# $3 = batch run list JSON (the one `gh run list --limit 100 ...` call)
# $4 = fallback mode: "ok:<json>" (fallback call succeeds with this JSON) or
#      "fail" (fallback call exits non-zero, as if gh errored)
make_fakegh() {
  local dir="$1" workflows="$2" batch="$3" fallback="$4"
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$dir/calls.log"
case "\$1 \$2" in
  "issue list") echo '[]' ;;
  "pr list") echo '[]' ;;
  "workflow list") cat <<'WF'
$workflows
WF
    ;;
  "run list")
    if [[ " \$* " == *" --workflow "* ]]; then
EOF
  if [ "$fallback" = "fail" ]; then
    cat >> "$dir/gh" <<'EOF'
      exit 1
EOF
  else
    cat >> "$dir/gh" <<EOF
      cat <<'FB'
${fallback#ok:}
FB
EOF
  fi
  cat >> "$dir/gh" <<EOF
    else
      cat <<'BATCH'
$batch
BATCH
    fi
    ;;
  *) echo '[]' ;;
esac
EOF
  chmod +x "$dir/gh"
}

# Runs the extracted "collect" step's run: block in a scratch cwd (it writes
# fabric-status.json to the cwd) with the given fake `gh` on PATH, for a
# single repo "repo1" in org "testorg". bash -e -c (not bare bash -c)
# reproduces the runner's real `bash --noprofile --norc -eo pipefail`
# semantics (#411) — a bug that only misbehaves under errexit would pass a
# bare `bash -c` harness and still break the real step.
run_collect() {
  local fakegh_dir="$1" scratch status_json rc
  scratch=$(mktemp -d)
  # Mirrors the real workflow's "Checkout SuxOS/.github (shared trust predicate)" step
  # (#551), which lands scripts/lib/is-trusted-author.jq at $GITHUB_WORKSPACE/.suxos-ci —
  # the collect step's jq `include` needs it at that same relative location here.
  mkdir -p "$scratch/.suxos-ci/scripts/lib"
  cp scripts/lib/is-trusted-author.jq "$scratch/.suxos-ci/scripts/lib/"
  ( cd "$scratch" && PATH="$fakegh_dir:$PATH" GH_TOKEN=x ORG=testorg REPOS=repo1 \
      EXCLUDE_LABELS="hold,blocked,throttle,epic" \
      NONBUILDABLE_LABELS="building,hold,needs-human,tracking" \
      STUCK_IDLE_DAYS=2 DISABLED_EXEMPT="" GITHUB_OUTPUT=/dev/null \
      GITHUB_WORKSPACE="$scratch" \
      bash -e -c "$collect_run" ) > "$scratch/log" 2>&1
  rc=$?
  status_json=""
  [ -f "$scratch/fabric-status.json" ] && status_json=$(cat "$scratch/fabric-status.json")
  echo "$rc|$status_json|$scratch"
}

field() { printf '%s' "$2" | jq -r ".repos[0]$1"; }

echo "[1/6] every workflow's latest run is inside the batch window -> counted from the batch, no fallback call"
d1=$(mktemp -d)
make_fakegh "$d1" \
  '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"active"},{"id":2,"name":"Sec","path":".github/workflows/security-review.yml","state":"active"}]' \
  '[{"workflowDatabaseId":1,"conclusion":"failure","status":"completed"},{"workflowDatabaseId":2,"conclusion":"success","status":"completed"}]' \
  'ok:[]'
: > "$d1/calls.log"
result=$(run_collect "$d1")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
if [ "$rc" -eq 0 ] && [ "$(field .workflow_red "$status_json")" = "1" ] \
    && [ "$(field .collection.runs "$status_json")" = "1" ] \
    && ! grep -q -- '--workflow' "$d1/calls.log"; then
  note "workflow_red=1 from the batch alone, no per-workflow fallback call issued"
else
  bad "batch-covered case: expected workflow_red=1/runs=1 with no --workflow fallback call (rc=$rc, status=$status_json, calls=$(cat "$d1/calls.log" 2>/dev/null))"
fi
rm -rf "$d1" "$scratch"

echo "[2/6] a workflow absent from the batch window -> per-workflow fallback is queried and counted"
d2=$(mktemp -d)
make_fakegh "$d2" \
  '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"active"},{"id":3,"name":"Nightly","path":".github/workflows/nightly.yml","state":"active"}]' \
  '[{"workflowDatabaseId":1,"conclusion":"success","status":"completed"}]' \
  'ok:[{"conclusion":"failure","status":"completed"}]'
: > "$d2/calls.log"
result=$(run_collect "$d2")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
if [ "$rc" -eq 0 ] && [ "$(field .workflow_red "$status_json")" = "1" ] \
    && [ "$(field .collection.runs "$status_json")" = "1" ] \
    && grep -q -- '--workflow 3' "$d2/calls.log"; then
  note "workflow_red=1 via per-workflow fallback for the workflow missing from the batch window"
else
  bad "fallback case: expected workflow_red=1/runs=1 with a --workflow 3 fallback call (rc=$rc, status=$status_json, calls=$(cat "$d2/calls.log" 2>/dev/null))"
fi
rm -rf "$d2" "$scratch"

echo "[3/6] the per-workflow fallback call itself errors -> collection.runs degrades to 0 (not a silent healthy zero)"
d3=$(mktemp -d)
make_fakegh "$d3" \
  '[{"id":9,"name":"Flaky","path":".github/workflows/flaky.yml","state":"active"}]' \
  '[]' \
  'fail'
result=$(run_collect "$d3")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
if [ "$rc" -eq 0 ] && [ "$(field .workflow_red "$status_json")" = "0" ] \
    && [ "$(field .collection.runs "$status_json")" = "0" ]; then
  note "collection.runs=0 (degraded) when the fallback gh call errors, workflow_red stays 0 rather than guessing"
else
  bad "fallback-error case: expected workflow_red=0/collection.runs=0 (rc=$rc, status=$status_json)"
fi
rm -rf "$d3" "$scratch"

echo "[4/6] workflow list hits the 101-row cap -> whole workflow collector degrades, no undercounted workflow_red"
d4=$(mktemp -d)
workflows_capped=$(jq -nc '[range(101) | {id: ., name: "wf\(.)", path: ".github/workflows/wf\(.).yml", state: "active"}]')
make_fakegh "$d4" "$workflows_capped" '[]' 'ok:[]'
result=$(run_collect "$d4")
rc="${result%%|*}"; rest="${result#*|}"; status_json="${rest%|*}"; scratch="${rest##*|}"
if [ "$rc" -eq 0 ] && [ "$(field .workflow_red "$status_json")" = "0" ] \
    && [ "$(field .collection.workflows "$status_json")" = "0" ] \
    && [ "$(field .collection.runs "$status_json")" = "0" ]; then
  note "a capped (>100) workflow list degrades collection.workflows AND collection.runs to 0, workflow_red left at 0 rather than an undercount"
else
  bad "cap-hit case: expected workflow_red=0/collection.workflows=0/collection.runs=0 (rc=$rc, status=$status_json)"
fi
rm -rf "$d4" "$scratch"

echo "[5/6] edge smoke checks configured -> per-service verdicts folded into fabric-status.json's edge_checks (SuxOS/.github#532 design doc §3.1)"
edge_run=$(yq -r '.jobs.spine.steps[] | select(.id == "edge") | .run' "$WF")
fold_run=$(yq -r '.jobs.spine.steps[] | select(.id == "fold-edge") | .run' "$WF")
d5=$(mktemp -d)
cat > "$d5/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *good*) echo -n 200; exit 0 ;;
    *bad*) echo -n 500; exit 0 ;;
  esac
done
echo -n 000
EOF
chmod +x "$d5/curl"
scratch5=$(mktemp -d)
echo '{"backlog_total":0}' > "$scratch5/fabric-status.json"
(
  cd "$scratch5" && PATH="$d5:$PATH" \
    EDGE_SMOKE_CHECKS=$'sux=https://good.example/mcp=200\nrouter=https://bad.example/mcp=200' \
    bash -e -c "$edge_run" && bash -e -c "$fold_run"
) > "$scratch5/log" 2>&1
rc5=$?
edge_checks5=$(jq -c '.edge_checks' "$scratch5/fabric-status.json" 2>/dev/null)
if [ "$rc5" -eq 0 ] && [ "$edge_checks5" = '[{"service":"sux","ok":true},{"service":"router","ok":false}]' ]; then
  note "edge_checks carries both services' verdicts (sux ok, router not ok)"
else
  bad "expected edge_checks with sux=true/router=false, got rc=$rc5 edge_checks=$edge_checks5 log=$(cat "$scratch5/log")"
fi
rm -rf "$d5" "$scratch5"

echo "[6/6] no edge smoke checks configured -> edge_checks folded in as an empty array, not omitted"
d6=$(mktemp -d)
scratch6=$(mktemp -d)
echo '{"backlog_total":0}' > "$scratch6/fabric-status.json"
(
  cd "$scratch6" && PATH="$d6:$PATH" EDGE_SMOKE_CHECKS="" \
    bash -e -c "$edge_run" && bash -e -c "$fold_run"
) > "$scratch6/log" 2>&1
rc6=$?
edge_checks6=$(jq -c '.edge_checks' "$scratch6/fabric-status.json" 2>/dev/null)
if [ "$rc6" -eq 0 ] && [ "$edge_checks6" = '[]' ]; then
  note "edge_checks is an explicit empty array when no edge smoke checks are configured"
else
  bad "expected edge_checks=[] with no edge checks configured, got rc=$rc6 edge_checks=$edge_checks6 log=$(cat "$scratch6/log")"
fi
rm -rf "$d6" "$scratch6"

echo "[7/7] Loki rollup jq filter: dotted .collection_ok in the if-condition, not the bare zero-arg-function form (#559)"
ship_run=$(yq -r '.jobs.spine.steps[] | select(.name == "Ship snapshot to Grafana Cloud (Prometheus + Loki)") | .run' .github/workflows/fabric-health.yml)
loki_filter=$(printf '%s\n' "$ship_run" | awk '/\{backlog:/,/needs_human: \$needs_human_total\}/' | sed -e "s/^ *'//" -e "s/}'.*/}/")
status_ok='{"collection_ok":1,"backlog_total":5,"backlog_zero":0,"budget_throttle_active":false}'
status_degraded='{"collection_ok":0,"backlog_total":5,"backlog_zero":0,"budget_throttle_active":false}'
out_ok=$(jq -c --argjson red_total 0 --argjson stuck_total 0 --argjson needs_human_total 0 "$loki_filter" <<< "$status_ok" 2>&1)
rc_ok=$?
out_degraded=$(jq -c --argjson red_total 0 --argjson stuck_total 0 --argjson needs_human_total 0 "$loki_filter" <<< "$status_degraded" 2>&1)
rc_degraded=$?
if [ "$rc_ok" -eq 0 ] && [ "$(jq -r .backlog <<< "$out_ok")" = "5" ] \
    && [ "$rc_degraded" -eq 0 ] && [ "$(jq -r .backlog <<< "$out_degraded")" = "null" ]; then
  note "jq filter compiles and gates backlog on .collection_ok (ok=$out_ok degraded=$out_degraded)"
else
  bad "Loki jq filter: expected valid output with backlog=5 when collection_ok=1 and backlog=null when collection_ok=0, got rc_ok=$rc_ok out_ok=$out_ok rc_degraded=$rc_degraded out_degraded=$out_degraded"
fi

[ "$fail" -eq 0 ] && { echo "fabric-health sweep regression guard: PASS"; exit 0; } || { echo "fabric-health sweep regression guard: FAIL"; exit 1; }
