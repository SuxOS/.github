#!/usr/bin/env bash
# Unit-tests scripts/check-live-hold-keep.sh (SuxOS/.github#461) — the shared live
# hold/keep re-check pr-unstick.yml's needs-human and security-review-retry sweeps use
# immediately before mutating a PR, against a mocked `gh`, with no network.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
SCRIPT="$(pwd)/scripts/check-live-hold-keep.sh"
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

run_case() {
  local gh_body="$1"
  # shellcheck disable=SC2317  # invoked indirectly via exported function
  gh() { eval "$gh_body"; }
  export -f gh
  export gh_body
  out=$(GH_REPO=SuxOS/example GH_TOKEN=x bash "$SCRIPT" 42)
  unset -f gh
  unset gh_body
  printf '%s' "$out"
}

echo "[1/3] neither hold nor keep present -> clear"
out=$(run_case 'echo "[\"automerge\"]"')
[ "$out" = "clear" ] && note "clear reported" || bad "expected clear, got $out"

echo "[2/3] hold present -> blocked"
out=$(run_case 'echo "[\"hold\"]"')
[ "$out" = "blocked" ] && note "blocked reported" || bad "expected blocked, got $out"

echo "[3/3] gh pr view fails -> fetch-failed (never a hard script failure)"
out=$(run_case 'exit 1')
[ "$out" = "fetch-failed" ] && note "fetch-failed reported" || bad "expected fetch-failed, got $out"

if [ "$fail" -eq 0 ]; then
  echo "check-live-hold-keep: PASS"
  exit 0
else
  echo "check-live-hold-keep: FAIL" >&2
  exit 1
fi
