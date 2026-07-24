#!/usr/bin/env bash
# Unit-tests the issue-build SPEND BREAKER (SuxOS/.github#725) — both halves:
#
#   1. The structural invariants that make the breaker load-bearing at all: the
#      `build` job's real `timeout-minutes` must equal the ceiling the breaker
#      classifies cancels against, and `select`/`requeue` must actually be gated
#      on it. A job-level `timeout-minutes:` cannot read `env`/`inputs`, so that
#      number is necessarily written twice; if the two drift, the breaker starts
#      counting operator cancels as timeouts (or stops counting real timeouts),
#      and nothing else in the repo would notice.
#
#   2. The classification itself, by driving .github/actions/red-streak's real
#      shipped `run:` block (extracted with yq — no hand-copied stand-in, so it
#      cannot drift from what actually runs) against canned `gh` fixtures.
#      The case that matters most is the negative one: a human `gh run cancel`
#      and a `timeout-minutes` kill are BOTH reported by GitHub as
#      `conclusion: cancelled`, and an operator stopping a run must never trip a
#      spend breaker.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)

WF=".github/workflows/issue-build.yml"
ACTION=".github/actions/red-streak/action.yml"
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Part 1 — structural invariants
# ---------------------------------------------------------------------------

echo "[1/10] build's timeout-minutes == the ceiling the breaker classifies against"
build_timeout=$(yq -r '.jobs.build."timeout-minutes"' "$WF" 2>/dev/null)
breaker_timeout=$(yq -r '.jobs.breaker.steps[] | select(.id == "streak") | .with."job-timeout-minutes"' "$WF" 2>/dev/null)
if [ -n "$build_timeout" ] && [ "$build_timeout" != "null" ] && [ "$build_timeout" = "$breaker_timeout" ]; then
  note "both are $build_timeout minutes"
else
  bad "build timeout-minutes='$build_timeout' but breaker job-timeout-minutes='$breaker_timeout' — a cancel at the real ceiling would be misclassified"
fi

echo "[2/10] select is gated on the breaker, fail-open on a breaker job failure"
select_if=$(yq -r '.jobs.select.if // ""' "$WF" 2>/dev/null)
select_needs=$(yq -r '[.jobs.select.needs] | flatten | join(",")' "$WF" 2>/dev/null)
case "$select_if" in
  *"needs.breaker.outputs.tripped != 'true'"*)
    case "$select_needs" in
      *breaker*)
        case "$select_if" in
          *"!cancelled()"*|*"always()"*)
            note "select needs breaker, skips only on a positive trip, and is fail-open on breaker failure" ;;
          *) bad "select's if has no status function, so an outright breaker FAILURE would silently halt the drain: '$select_if'" ;;
        esac ;;
      *) bad "select does not declare 'needs: breaker' (needs='$select_needs')" ;;
    esac ;;
  *) bad "select is not gated on the breaker (if='$select_if')" ;;
esac

echo "[3/10] requeue's fan-out is gated on the breaker too"
requeue_needs=$(yq -r '[.jobs.requeue.needs] | flatten | join(",")' "$WF" 2>/dev/null)
fanout_if=$(yq -r '.jobs.requeue.steps[] | select(.name | test("Fan out")) | .if // ""' "$WF" 2>/dev/null)
if [[ "$requeue_needs" == *breaker* ]] && [[ "$fanout_if" == *"needs.breaker.outputs.tripped != 'true'"* ]]; then
  note "requeue cannot dispatch fresh batches into a stood-down repo"
else
  bad "requeue needs='$requeue_needs' fan-out if='$fanout_if' — requeue re-derives backlog itself, so an ungated fan-out defeats the breaker entirely"
fi

echo "[4/10] the latch title is defined once and used by both the read and the write"
title=$(yq -r '.env.BREAKER_TITLE // ""' "$WF" 2>/dev/null)
trip_title=$(yq -r '.jobs.breaker.steps[] | select(.uses | test("upsert-tracking-issue")) | .with.title' "$WF" 2>/dev/null)
if [ -n "$title" ] && [ "$trip_title" = '${{ env.BREAKER_TITLE }}' ]; then
  note "one title ('$title'), referenced rather than repeated"
else
  bad "env.BREAKER_TITLE='$title' but the trip step writes title='$trip_title' — a divergence files a new issue every cycle instead of latching"
fi

# ---------------------------------------------------------------------------
# Part 2 — classification, against the real shipped run: block
# ---------------------------------------------------------------------------

STREAK_BLOCK=$(yq -r '.runs.steps[] | select(.id == "streak") | .run' "$ACTION" 2>/dev/null)
if [ -z "$STREAK_BLOCK" ]; then
  echo "  FAIL: could not extract red-streak's streak step from $ACTION" >&2
  exit 1
fi

# A `build` job as the runs/{id}/jobs endpoint reports it. GitHub prefixes a reusable
# workflow's job names with the caller's job id, which the action's matcher has to handle.
job_fixture() { # conclusion started completed
  printf '{"jobs":[{"name":"issue-build / build","conclusion":"%s","started_at":"%s","completed_at":"%s"}]}' "$1" "$2" "$3"
}
TIMEOUT_JOB=$(job_fixture cancelled "2026-07-24T02:21:29Z" "2026-07-24T02:51:48Z")   # 30m19s — at the 30m ceiling
USERCANCEL_JOB=$(job_fixture cancelled "2026-07-24T02:21:29Z" "2026-07-24T02:25:29Z") # 4m — an operator stopped it
SUCCESS_JOB=$(job_fixture success "2026-07-24T02:21:29Z" "2026-07-24T02:33:00Z")
SKIPPED_JOB=$(job_fixture skipped "2026-07-24T02:21:29Z" "2026-07-24T02:21:30Z")
NO_BUILD_JOB='{"jobs":[{"name":"issue-build / select","conclusion":"success","started_at":"2026-07-24T02:21:29Z","completed_at":"2026-07-24T02:22:00Z"}]}'
# The jobs-endpoint fixtures are read by the `gh` shim inside the child shell.
export TIMEOUT_JOB USERCANCEL_JOB SUCCESS_JOB SKIPPED_JOB NO_BUILD_JOB

# $1 name, $2 runs-list JSON (or the literal RUNLIST_FAILS), $3 a case body over $id,
# $4.. extra env assignments.
run_case() {
  local name="$1" runs="$2" jobs_case="$3"; shift 3
  local out_file rc
  # shellcheck disable=SC2317  # invoked indirectly through the exported function
  gh() {
    case "$1" in
      run)
        [ "$RUNS_FIXTURE" = "RUNLIST_FAILS" ] && return 1
        printf '%s' "$RUNS_FIXTURE"
        ;;
      api)
        local id="${2#*/actions/runs/}"; id="${id%%/*}"
        eval "$JOBS_CASE"
        ;;
      *) return 1 ;;
    esac
  }
  export -f gh
  RUNS_FIXTURE="$runs" JOBS_CASE="$jobs_case"
  export RUNS_FIXTURE JOBS_CASE
  out_file=$(mktemp)
  out=$(
    env GITHUB_OUTPUT="$out_file" \
        REPO=SuxOS/.github WORKFLOW=self-issue-build.yml JOB_NAME=build \
        JOB_TIMEOUT_MINUTES=30 MARGIN_MINUTES=2 \
        RED_CONCLUSIONS=timed_out,timeout_cancelled THRESHOLD=3 SCAN_LIMIT=12 SINCE="" \
        "$@" \
        bash -e -c "$STREAK_BLOCK" 2>&1
  )
  rc=$?
  streak=$(grep -m1 '^streak=' "$out_file" | cut -d= -f2)
  tripped=$(grep -m1 '^tripped=' "$out_file" | cut -d= -f2)
  ok=$(grep -m1 '^ok=' "$out_file" | cut -d= -f2)
  rm -f "$out_file"
  unset -f gh
  unset RUNS_FIXTURE JOBS_CASE
  echo "  [$name] exit=$rc streak=$streak tripped=$tripped ok=$ok"
  return "$rc"
}

# Completed runs in newest-first order, as `gh run list --json` returns them (createdAt
# descending, one day apart, so the acknowledgement-floor case has something to compare).
runs_list() { # id1 id2 id3 ...
  local out="[" first=1 n=0 id day
  for id in "$@"; do
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    n=$((n + 1))
    day=$(printf '%02d' $((25 - n)))
    out="$out{\"databaseId\":$id,\"status\":\"completed\",\"conclusion\":\"cancelled\",\"createdAt\":\"2026-07-${day}T02:00:00Z\",\"url\":\"https://github.com/SuxOS/.github/actions/runs/$id\"}"
  done
  printf '%s]' "$out"
}

echo "[5/10] three consecutive TIMEOUT-cancels trip the breaker"
run_case "three-timeouts" "$(runs_list 3 2 1)" "printf '%s' \"\$TIMEOUT_JOB\""
if [ "$tripped" = "true" ] && [ "$streak" = "3" ] && [ "$ok" = "1" ]; then
  note "a full-budget cancel is counted as the timeout it is"
else
  bad "expected tripped=true streak=3 ok=1, got tripped=$tripped streak=$streak ok=$ok"
fi

echo "[6/10] three consecutive USER cancels do NOT trip the breaker"
run_case "three-user-cancels" "$(runs_list 3 2 1)" "printf '%s' \"\$USERCANCEL_JOB\""
if [ "$tripped" = "false" ] && [ "$streak" = "0" ] && [ "$ok" = "1" ]; then
  note "an operator running 'gh run cancel' cannot stand the loop down"
else
  bad "expected tripped=false streak=0 ok=1, got tripped=$tripped streak=$streak ok=$ok — a user cancel must never trip the breaker"
fi

echo "[7/10] a real build success resets the streak"
run_case "success-resets" "$(runs_list 3 2 1)" \
  'case "$id" in 3) printf "%s" "$SUCCESS_JOB" ;; *) printf "%s" "$TIMEOUT_JOB" ;; esac'
if [ "$tripped" = "false" ] && [ "$streak" = "0" ]; then
  note "the walk stops at the first genuine success"
else
  bad "expected tripped=false streak=0, got tripped=$tripped streak=$streak"
fi

echo "[8/10] a stood-down cycle (no build job / skipped build) is neutral, not a recovery"
run_case "stood-down-neutral" "$(runs_list 5 4 3 2 1)" \
  'case "$id" in 4) printf "%s" "$NO_BUILD_JOB" ;; 2) printf "%s" "$SKIPPED_JOB" ;; *) printf "%s" "$TIMEOUT_JOB" ;; esac'
if [ "$tripped" = "true" ] && [ "$streak" = "3" ]; then
  note "the breaker's own no-op runs cannot silently re-arm it"
else
  bad "expected tripped=true streak=3, got tripped=$tripped streak=$streak"
fi

echo "[9/10] a degraded read reports ok=0 and never trips"
run_case "runlist-fails" "RUNLIST_FAILS" "printf '%s' \"\$TIMEOUT_JOB\""
if [ "$tripped" = "false" ] && [ "$ok" = "0" ] && printf '%s' "$out" | grep -q '::warning::red-streak'; then
  note "a failed query is loud and asserts nothing, rather than reading as a healthy zero"
else
  bad "expected tripped=false ok=0 plus a ::warning::, got tripped=$tripped ok=$ok out=$out"
fi

echo "[10/10] the acknowledgement floor stops already-cleared history from re-tripping"
# runs_list stamps createdAt as 2026-07-{24,23,22}; a floor newer than all three must count
# nothing, or closing the tracking issue could never actually resume the loop.
run_case "since-floor" "$(runs_list 3 2 1)" "printf '%s' \"\$TIMEOUT_JOB\"" SINCE=2026-07-25T00:00:00Z
if [ "$tripped" = "false" ] && [ "$streak" = "0" ]; then
  note "closing the breaker's tracking issue genuinely re-arms the loop"
else
  bad "expected tripped=false streak=0 behind the floor, got tripped=$tripped streak=$streak"
fi

if [ "$fail" -ne 0 ]; then
  echo "FAILED" >&2
  exit 1
fi
echo "all issue-build timeout-breaker invariants hold"
