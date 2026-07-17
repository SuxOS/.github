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
GRAFANA_README="grafana/README.md"
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

# --- Conditionally-emitted metrics (#291 class) -------------------------------
# A series is CONDITIONALLY emitted when fabric-health.yml can legitimately
# produce ZERO lines for it on a given tick — as opposed to always printing a
# value (even 0). Aggregating such a series with min_over_time/count_over_time/
# count() and no `or vector(...)` fallback reads "healthy green" when the
# underlying condition simply didn't occur this window (#291), not when it's
# actually healthy. Detected via three deterministic shapes found in the
# workflow's own step/jq structure — no execution needed:
#   (a) the metric's step contains a guard `exit 0` earlier in the script (e.g.
#       the edge-smoke step no-ops entirely when unconfigured) — everything the
#       step emits is conditional on that guard;
#   (b) the printf immediately follows a bash `if ... ; then` line (a directly
#       wrapped emission, e.g. suxos_pipeline_backlog inside collection_ok==1);
#   (c) the enclosing `jq -r ... '...' <<< "$status"` statement contains a
#       `select(...)` filter or a `[]?` optional array iteration — both can
#       legitimately produce zero output rows.
declare -A CONDITIONAL_METRICS   # metric -> human-readable reason (why it's conditional)
parse_conditional() {
  local -a fh_lines
  mapfile -t fh_lines < "$FABRIC_HEALTH"
  local n=${#fh_lines[@]}
  local -a step_idx=()
  local i
  for ((i = 0; i < n; i++)); do
    [[ "${fh_lines[$i]}" =~ ^[[:space:]]*-\ name: ]] && step_idx+=("$i")
  done
  step_idx+=("$n")

  step_has_exit_guard() {
    local at="$1" j s e k
    for ((j = 0; j < ${#step_idx[@]} - 1; j++)); do
      s=${step_idx[$j]}; e=${step_idx[$((j + 1))]}
      if [ "$at" -ge "$s" ] && [ "$at" -lt "$e" ]; then
        for ((k = s; k < e; k++)); do
          [[ "${fh_lines[$k]}" == *"exit 0"* ]] && { echo 1; return; }
        done
      fi
    done
    echo 0
  }

  # Precompute jq statement ranges [start,end] ONCE (not per-metric with an
  # unbounded backward/forward search, which could bleed into a neighboring
  # statement and mis-tag an unrelated plain `printf` as jq-conditional).
  local -a jq_start=() jq_end=()
  local in_jq=0 cur_start=-1
  for ((i = 0; i < n; i++)); do
    if [ "$in_jq" -eq 0 ]; then
      if [[ "${fh_lines[$i]}" =~ jq\ -r ]]; then
        in_jq=1; cur_start=$i
        [[ "${fh_lines[$i]}" == *'<<< "$status"'* ]] && { jq_start+=("$cur_start"); jq_end+=("$i"); in_jq=0; }
      fi
    else
      if [[ "${fh_lines[$i]}" == *'<<< "$status"'* ]]; then
        jq_start+=("$cur_start"); jq_end+=("$i"); in_jq=0
      fi
    fi
  done

  jq_range_for_line() {
    local at="$1" j
    for ((j = 0; j < ${#jq_start[@]}; j++)); do
      if [ "$at" -ge "${jq_start[$j]}" ] && [ "$at" -le "${jq_end[$j]}" ]; then
        echo "$j"; return
      fi
    done
    echo -1
  }

  local line metric reason pj r k blk
  for ((i = 0; i < n; i++)); do
    line="${fh_lines[$i]}"
    [[ "$line" =~ suxos_[a-z0-9_]+.*value= ]] || continue
    metric=$(grep -oE 'suxos_[a-z0-9_]+' <<<"$line" | head -1)
    [ -z "$metric" ] && continue
    [[ -v CONDITIONAL_METRICS["$metric"] ]] && continue
    reason=""
    r=$(jq_range_for_line "$i")
    if [ "$r" -ge 0 ]; then
      blk=""
      for ((k = "${jq_start[$r]}"; k <= "${jq_end[$r]}"; k++)); do blk+="${fh_lines[$k]}"$'\n'; done
      if [[ "$blk" == *"select("* ]]; then
        reason="its jq filter uses select(...)"
      elif [[ "$blk" == *"[]?"* ]]; then
        reason="its jq filter uses an optional '[]?' array iteration"
      fi
    else
      pj=$((i - 1))
      while [ "$pj" -ge 0 ] && [[ -z "${fh_lines[$pj]//[[:space:]]/}" ]]; do pj=$((pj - 1)); done
      [ "$pj" -ge 0 ] && [[ "${fh_lines[$pj]}" =~ then[[:space:]]*$ ]] && \
        reason="wrapped directly in a bash 'if ... then' guard"
    fi
    if [ -z "$reason" ] && [ "$(step_has_exit_guard "$i")" = "1" ]; then
      reason="its step no-ops via an early 'exit 0' guard"
    fi
    [ -n "$reason" ] && CONDITIONAL_METRICS["$metric"]="$reason"
  done
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

  # (5) Conditional-series aggregation without an `or vector(...)` fallback
  # (#291 class): min_over_time/count_over_time/count() over a metric that
  # fabric-health.yml only emits some ticks (CONDITIONAL_METRICS) can read
  # stale-green when the underlying condition just never occurred this
  # window, unless the expr also handles the no-data case via `or vector(...)`.
  if grep -qP '\b(min_over_time|count_over_time|count)\s*\(' <<<"$expr" && ! grep -q 'or vector(' <<<"$expr"; then
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      [[ -v CONDITIONAL_METRICS["$m"] ]] && \
        echo "VIOLATION [$ctx]: aggregates conditionally-emitted metric '$m' (${CONDITIONAL_METRICS[$m]}) with no 'or vector(...)' fallback — can read stale-green when the condition doesn't occur this window (#291)"
    done < <(grep -oE 'suxos_[a-z0-9_]+' <<<"$expr" | sort -u)
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
parse_conditional
echo "conditionally-emitted metrics: ${!CONDITIONAL_METRICS[*]}"

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
expect_v "age window == threshold (#320)"    'count((timestamp(suxos_workflow_disabled) - min_over_time(timestamp(suxos_workflow_disabled)[48h:15m])) >= 172800) or vector(0)' 1
expect_v "age window > threshold (fixed)"    'count((timestamp(suxos_workflow_disabled) - min_over_time(timestamp(suxos_workflow_disabled)[49h:15m])) >= 172800) or vector(0)' 0
expect_v "conditional series aggregated, no fallback (#291)" 'min_over_time(suxos_pr_red_total[20m])'        1
expect_v "conditional series aggregated, with vector fallback (fixed)" 'min_over_time(suxos_pr_red_total[20m]) or vector(0)' 0
expect_v "count() over a conditionally-emitted series, no fallback" 'count(suxos_workflow_disabled)'          1
expect_v "aggregation over an unconditional series needs no fallback" 'min_over_time(suxos_backlog_zero[7d])' 0

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

# ===========================================================================
# Part C — grafana/README.md's hand-maintained metric table vs the emitted
# surface (#342). The query gate above catches drift in *exprs*; this catches
# the sibling class in *docs*: a renamed/added series that the README table
# never picked up. Parses `| \`suxos_x\` | \`tag\`, ... | desc |` rows and
# checks set-equality against EMITTED_LABELS (derived above from
# fabric-health.yml, the source of truth — never from this README itself).
# ===========================================================================
echo "[C] validate grafana/README.md's metric table against the emitted surface"
declare -A DOC_LABELS
parse_readme_table() {
  local target="$1" metriccol tagscol metric tag tags
  while IFS='|' read -r _ metriccol tagscol _rest; do
    metric=$(grep -oP '(?<=`)suxos_[a-z0-9_]+(?=`)' <<<"$metriccol")
    [ -z "$metric" ] && continue
    tags=""
    while IFS= read -r tag; do
      [ -z "$tag" ] && continue
      tags="${tags:+$tags }$tag"
    done < <(grep -oP '(?<=`)[a-zA-Z_][a-zA-Z0-9_]*(?=`)' <<<"$tagscol")
    DOC_LABELS["$metric"]="$tags"
  done < <(grep -P '^\|\s*`suxos_' "$target")
}

# Self-test first (same rationale as Part A): a broken table parser must not
# silently pass every doc-drift check through unchecked.
readme_selftest=$(mktemp)
cat >"$readme_selftest" <<'EOF'
| Series | Tags | Meaning |
| --- | --- | --- |
| `suxos_backlog_zero` | — | fine |
| `suxos_ghost_metric` | — | never emitted, should fail |
| `suxos_pr_open_total` | `repo` | fine |
| `suxos_collection_ok` | `repo`, `ghost_tag` | tag never emitted, should fail |
EOF
parse_readme_table "$readme_selftest"
rm -f "$readme_selftest"
st_fail=0
for m in "${!DOC_LABELS[@]}"; do
  if [[ ! -v EMITTED_LABELS["$m"] ]]; then
    [ "$m" = "suxos_ghost_metric" ] && st_fail=$((st_fail + 1))
  fi
done
for tag in ${DOC_LABELS[suxos_collection_ok]:-}; do
  case " ${EMITTED_LABELS[suxos_collection_ok]:-} " in
    *" $tag "*) : ;;
    *) [ "$tag" = "ghost_tag" ] && st_fail=$((st_fail + 1)) ;;
  esac
done
if [ "$st_fail" -eq 2 ]; then
  note "readme table self-test -> caught both synthetic defects"
else
  bad "readme table self-test: expected to catch 2 synthetic defects, caught $st_fail — parser may be silently no-op'ing"
fi
unset DOC_LABELS
declare -A DOC_LABELS

parse_readme_table "$GRAFANA_README"
for m in "${!DOC_LABELS[@]}"; do
  if [[ ! -v EMITTED_LABELS["$m"] ]]; then
    bad "grafana/README.md documents metric '$m' that $FABRIC_HEALTH never emits"
    continue
  fi
  for tag in ${DOC_LABELS[$m]}; do
    case " ${EMITTED_LABELS[$m]} " in
      *" $tag "*) : ;;
      *) bad "grafana/README.md documents tag '$tag' on '$m', which emits no such label (has: ${EMITTED_LABELS[$m]:-<none>})" ;;
    esac
  done
done
for m in "${!EMITTED_LABELS[@]}"; do
  [[ -v DOC_LABELS["$m"] ]] || note "grafana/README.md is missing a row for emitted metric '$m' (warning, not a failure)"
done
[ "${#DOC_LABELS[@]}" -gt 0 ] && note "grafana/README.md: ${#DOC_LABELS[@]} documented metric(s) checked against the emitted surface"

[ "$fail" -eq 0 ] && { echo "dashboard-queries: PASS"; exit 0; } || { echo "dashboard-queries: FAIL"; exit 1; }
