#!/usr/bin/env bash
# Unit-tests the security-review no-verdict classifier
# (scripts/classify-security-noverdict.sh) — the fail-closed decision that closes
# SuxOS/.github#209 and makes #236's rate-limit case requeue instead of merge-blocking
# permanently or (worse) passing unreviewed. No network, no live gh.
#
# INVARIANT under test: `infra` is returned ONLY on a genuine account-level rate-limit
# signal; everything else (empty logs, refusal/looping output, unreadable input) ->
# `fail-closed`. A regression that flips an ambiguous no-verdict to `infra` would let a
# starved reviewer's PR skip the block — the exact evasion #209 is about.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root
SCRIPT="$(pwd)/scripts/classify-security-noverdict.sh"
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

# Feed $2 as a synthetic execution log on stdin, assert stdout == $3.
run_case() {
  local name="$1" log="$2" want="$3"
  local got
  got=$(printf '%s' "$log" | bash "$SCRIPT")
  if [ "$got" = "$want" ]; then note "[$name] -> $got"; else bad "[$name] expected '$want', got '$got'"; fi
}

echo "[1] account five-hour rate-limit (rate_limit_event) -> infra"
run_case "rate_limit_event" '{"type":"rate_limit_event","rateLimitType":"five_hour","resetsAt":1784167800} security-review did not finish (no verdict)' infra

echo "[2] typed five_hour limit, alternate spacing/quoting -> infra"
run_case "five_hour-typed" '{ "rateLimitType" : "five_hour" }' infra

echo "[3] empty log (reviewer emitted nothing, no signal) -> fail-closed"
run_case "empty" '' fail-closed

echo "[4] reviewer ran but starved on the diff, NO infra signal -> fail-closed (closes #209)"
run_case "starved-no-signal" '{"type":"assistant","text":"I will not review this."} max turns reached, no structured output' fail-closed

echo "[5] a generic resetsAt WITHOUT a rate-limit marker must NOT be read as infra -> fail-closed"
run_case "resetsAt-alone" '{"resetsAt":1784167800,"note":"some unrelated field"}' fail-closed

echo "[6] no args, no stdin (both attempts produced no file) -> fail-closed"
if [ "$(bash "$SCRIPT" </dev/null)" = "fail-closed" ]; then note "[no-input] -> fail-closed"; else bad "[no-input] expected fail-closed"; fi

echo "[7] real execution-file path arg carrying the signal -> infra"
tmp="$(mktemp)"; printf '%s\n' '{"type":"rate_limit_event"}' > "$tmp"
if [ "$(bash "$SCRIPT" "$tmp" </dev/null)" = "infra" ]; then note "[file-arg] -> infra"; else bad "[file-arg] expected infra"; fi
rm -f "$tmp"

echo "[8] unreadable/missing file path arg is ignored -> fail-closed"
if [ "$(bash "$SCRIPT" /nonexistent/path/nope.json </dev/null)" = "fail-closed" ]; then note "[missing-file] -> fail-closed"; else bad "[missing-file] expected fail-closed"; fi

if [ "$fail" -ne 0 ]; then echo "FAILED" >&2; exit 1; fi
echo "all classify-security-noverdict cases passed"
