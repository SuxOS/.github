#!/usr/bin/env bash
# Dashboard-query invariant gate (SuxOS/.github#339).
#
# CLAUDE.md/README long said "Nothing gates grafana/*.json beyond JSON syntax —
# no PromQL linting — so reason dashboard-query edits by hand." That gap shipped
# panels that can never fire or always fire and cost a builder run each to catch:
#   #319 — a matcher on a `throttle` label nothing applies
#   #320/#304 — an age-span subquery window equal to (not wider than) its threshold
#   #291 — aggregation over an emit-only-when-disabled series
# This script closes the deterministic slice of that class with NO network: it
# derives the metric/label surface fabric-health.yml ACTUALLY emits (the single
# `printf`/`jq -n` line-protocol block, source of truth — not grafana/README.md,
# which is hand-maintained docs and can drift) and cross-checks every `expr` in
# grafana/*.json against it. A reference to a metric or label nothing produces,
# or an age threshold a subquery window can't structurally exceed, fails the run.
#
# Wired into self-check.yml by name (the repo's explicit-not-glob convention).
# Self-verifying: it first feeds its own checker known-bad and known-good exprs
# so a silently no-op'ing checker (e.g. a broken grep) fails loudly here rather
# than passing every dashboard through unchecked.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)

FABRIC_HEALTH=".github/workflows/fabric-health.yml"
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

# --- Emitted surface: metric -> its label keys, parsed from fabric-health.yml ---
# The spine emits Influx line protocol `suxos_NAME[,key=val,...] value=<n> <ts>`
# from `printf` and `jq -r` strings. Anchoring on the literal ` value=` that
# terminates every series identifier picks up ONLY real emissions, never the
# suxos_* names that appear in prose comments (which are not followed by value=).
declare -A EMITTED_LABELS      # metric -> space-separated label keys ("" if none)
declare -A EMITTED_LABEL_UNION # every label key emitted by any series -> 1
parse_emitted() {
  local series metric labelpart p key
  while IFS= read -r series; do
    metric="${series%%,*}"
    # Register the metric even when it carries no labels, so "emitted, no labels"
    # is distinguishable from "not emitted at all".
    [[ -v EMITTED_LABELS["$metric"] ]] || EMITTED_LABELS["$metric"]=""
    if [[ "$series" == *,* ]]; then
      labelpart="${series#*,}"
      IFS=',' read -ra _parts <<<"$labelpart"
      for p in "${_parts[@]}"; do
        key="${p%%=*}"
        [ -z "$key" ] && continue
        case " ${EMITTED_LABELS[$metric]} " in
          *" $key "*) : ;;
          *) EMITTED_LABELS["$metric"]="${EMITTED_LABELS[$metric]:+${EMITTED_LABELS[$metric]} }$key" ;;
        esac
        EMITTED_LABEL_UNION["$key"]=1
      done
    fi
  done < <(grep -oE 'suxos_[^ ]* value=' "$FABRIC_HEALTH" | sed 's/ value=$//' | sort -u)
}

# --- Duration literal (Prometheus: 49h, 7d, 20m, 15m, ...) to seconds ---
dur_to_secs() {
  local d="$1" n u
  n="${d%[smhdwy]}"; u="${d: -1}"
  case "$u" in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    w) echo $((n * 604800)) ;;
    y) echo $((n * 31536000)) ;;
    *) echo 0 ;;
  esac
}

# --- Validate ONE expr; print one `VIOLATION` line per defect found ---
check_expr() {
  local expr="$1" ctx="$2" m sel mm braces lk grp g w t s win_secs

  # (1) Metric existence: every suxos_* identifier must be an emitted series.
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    [[ -v EMITTED_LABELS["$m"] ]] || \
      echo "VIOLATION [$ctx]: references metric '$m' that $FABRIC_HEALTH never emits"
  done < <(grep -oE 'suxos_[a-z0-9_]+' <<<"$expr" | sort -u)

  # (2) Label matchers `suxos_metric{key=...}`: the key must exist ON THAT metric
  # (the #319 class — a matcher on a label the series never carries selects nothing).
  # Only checked when the metric IS emitted; an unknown metric is already flagged in (1).
  while IFS= read -r sel; do
    [ -z "$sel" ] && continue
    mm="${sel%%\{*}"; mm="${mm// /}"
    braces="${sel#*\{}"; braces="${braces%\}}"
    [[ -v EMITTED_LABELS["$mm"] ]] || continue
    while IFS= read -r lk; do
      [ -z "$lk" ] && continue
      case " ${EMITTED_LABELS[$mm]} " in
        *" $lk "*) : ;;
        *) echo "VIOLATION [$ctx]: matcher {$lk=...} on '$mm', which emits no such label (has: ${EMITTED_LABELS[$mm]:-<none>})" ;;
      esac
    done < <(grep -oP '[a-zA-Z_][a-zA-Z0-9_]*(?=\s*(=~|!~|!=|=))' <<<"$braces")
  done < <(grep -oP 'suxos_[a-z0-9_]+\s*\{[^}]*\}' <<<"$expr")

  # (3) Grouping labels `by (...)` / `without (...)`: checked against the UNION of
  # emitted labels (precise per-metric attribution needs a full PromQL parser; the
  # union still catches a typo'd or never-emitted grouping label).
  while IFS= read -r grp; do
    [ -z "$grp" ] && continue
    IFS=',' read -ra _gl <<<"$grp"
    for g in "${_gl[@]}"; do
      g="${g// /}"
      [ -z "$g" ] && continue
      [[ -v EMITTED_LABEL_UNION["$g"] ]] || \
        echo "VIOLATION [$ctx]: groups by label '$g' that no emitted series carries"
    done
  done < <(grep -oP '\b(by|without)\s*\(\s*\K[^)]*' <<<"$expr")

  # (4) Threshold-vs-window (#320/#304): an age-span panel subtracts a series'
  # timestamp from its min-over-a-subquery-window and compares `>= <seconds>`. A
  # left-open subquery `[W:...]` only sees samples strictly newer than now-W, so
  # the measured age is structurally < W — the window MUST be wider than the
  # threshold or the panel can never fire. Scoped to exprs doing timestamp() math
  # over a subquery window, so ordinary count thresholds (`>= 1`) are untouched.
  # A subquery window `[W:step]` (colon-bearing bracket) only occurs inside a
  # range function; pairing it with timestamp() arithmetic is the age-span
  # signature, so gate on those two facts rather than the exact function nesting.
  if grep -q 'timestamp(' <<<"$expr" && grep -qP '\[[0-9]+[smhdwy]:' <<<"$expr"; then
    win_secs=0
    while IFS= read -r w; do
      s=$(dur_to_secs "$w")
      [ "$s" -gt "$win_secs" ] && win_secs="$s"
    done < <(grep -oP '\[\K[0-9]+[smhdwy](?=[:\]])' <<<"$expr")
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      if [ "$win_secs" -le "$t" ]; then
        echo "VIOLATION [$ctx]: age-span window ${win_secs}s is not strictly wider than threshold ${t}s — panel can never fire (threshold-vs-window, #320/#304)"
      fi
    done < <(grep -oP '(>=|>)\s*\K[0-9]+' <<<"$expr")
  fi
}

# Count VIOLATION lines emitted by check_expr for a given expr.
count_violations() {
  local out
  out="$(check_expr "$1" "$2")"
  [ -z "$out" ] && { echo 0; return; }
  printf '%s\n' "$out" | grep -c 'VIOLATION'
}

parse_emitted
echo "emitted metrics: ${!EMITTED_LABELS[*]}"
echo "emitted labels:  ${!EMITTED_LABEL_UNION[*]}"

# ===========================================================================
# Part A — self-test the checker against synthetic known-bad / known-good exprs
# so a broken checker (bad regex, empty emitted map) can't silently pass every
# real dashboard through unchecked.
# ===========================================================================
echo "[A] self-test the checker"
expect_v() {
  local desc="$1" expr="$2" want="$3" got
  got=$(count_violations "$expr" "selftest")
  if [ "$got" = "$want" ]; then
    note "$desc -> $got violation(s)"
  else
    bad "$desc: expected $want violation(s), got $got for expr: $expr"
  fi
}
expect_v "clean bare metric"                 'suxos_pipeline_backlog'                                        0
expect_v "clean range + by-repo grouping"    'sum by (repo) (last_over_time(suxos_workflow_red_total[20m]))' 0
expect_v "clean matcher on a valid label"    'suxos_collection_ok{repo="sux"}'                              0
expect_v "unknown metric"                    'last_over_time(suxos_not_a_metric[20m])'                      1
expect_v "matcher on a nonexistent label"    'suxos_budget_throttle_active{throttle="red"}'                 1
expect_v "matcher label wrong for metric"    'suxos_pr_red_total{service="x"}'                              1
expect_v "grouping by a typo'd label"        'sum by (reepo) (suxos_pr_red_total)'                          1
expect_v "age window == threshold (#320)"    'count((timestamp(suxos_workflow_disabled) - min_over_time(timestamp(suxos_workflow_disabled)[48h:15m])) >= 172800)' 1
expect_v "age window > threshold (fixed)"    'count((timestamp(suxos_workflow_disabled) - min_over_time(timestamp(suxos_workflow_disabled)[49h:15m])) >= 172800)' 0

# ===========================================================================
# Part B — live gate: every expr in the real grafana/*.json must be clean.
# ===========================================================================
echo "[B] validate live grafana/*.json exprs"
shopt -s nullglob
dashboards=(grafana/*.json)
if [ "${#dashboards[@]}" -eq 0 ]; then
  bad "no grafana/*.json dashboards found — expected at least one to validate"
fi
for f in "${dashboards[@]}"; do
  # Recurse so exprs inside row-nested panels are covered too.
  exprs="$(jq -r '.. | objects | select(has("expr")) | .expr' "$f" 2>/dev/null)"
  if [ -z "$exprs" ]; then
    note "$f: no exprs to check"
    continue
  fi
  fcount=0
  while IFS= read -r expr; do
    [ -z "$expr" ] && continue
    out="$(check_expr "$expr" "$f")"
    if [ -n "$out" ]; then
      # No pipe here: a `bad` inside `... | while` runs in a subshell and its
      # fail=1 would not propagate. Feed the lines via a here-string instead.
      while IFS= read -r line; do bad "$line"; done <<<"$out"
      fcount=$((fcount + 1))
    fi
  done <<<"$exprs"
  [ "$fcount" -eq 0 ] && note "$f: all exprs reference emitted metrics/labels and are fireable"
done

[ "$fail" -eq 0 ] && { echo "dashboard-queries: PASS"; exit 0; } || { echo "dashboard-queries: FAIL"; exit 1; }
