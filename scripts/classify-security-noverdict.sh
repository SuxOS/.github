#!/usr/bin/env bash
# Classify a security-review NO-VERDICT outcome by CAUSE, so the Gate step in
# security-review.yml can decide the right (fail-closed) response.
#
# Why this exists (SuxOS/.github#236 + #209): when the Claude review steps produce no
# structured verdict, the Gate cannot tell "the reviewer was starved / refused / looped
# on this diff" (an EVASION vector — must FAIL CLOSED, #209) apart from "the account hit
# a five-hour rate limit before it could review" (transient INFRA gap, not diff-controllable
# — must NOT permanently block and must NOT pass, #236). The ONLY difference is a signal in
# the claude-code-action execution log, so we read it here.
#
# Contract:
#   - Args: zero or more paths to claude-code-action `execution_file` outputs (JSON logs).
#     Missing/empty/unreadable files are ignored (treated as "no signal").
#   - Also reads stdin if piped (lets the unit test feed synthetic logs without temp files).
#   - Prints exactly one classification token to stdout and exits 0:
#       infra        -> account-level rate-limit / usage-limit signal present. NOT
#                       diff-controllable. Caller must emit a non-passing, AUTO-REQUEUED
#                       outcome (block this run, no `hold`, re-run after the limit resets).
#       fail-closed  -> no infra signal. The reviewer ran but emitted nothing usable on
#                       THIS diff (refusal, looping, max-turns/timeout) — the evasion vector.
#                       Caller must FAIL CLOSED (`hold` + block).
#
# SECURITY INVARIANT: the only path that yields `infra` is a genuine account-level
# rate-limit signal. Any ambiguity, unreadable input, or unrecognized failure -> `fail-closed`.
# Fail closed on any internal error too (a crash must never be read as "infra, don't block").
set -uo pipefail

emit() { printf '%s\n' "$1"; exit 0; }
# A hard error in this classifier itself must never ungate: default to fail-closed.
trap 'printf "fail-closed\n"; exit 0' ERR

blob=""
# Concatenate any readable file args (missing/empty ignored) ...
for f in "$@"; do
  if [ -n "$f" ] && [ -r "$f" ]; then
    blob+=$(cat -- "$f" 2>/dev/null || true)
    blob+=$'\n'
  fi
done
# ... plus stdin when piped (not a tty), so tests can feed logs directly.
if [ ! -t 0 ]; then
  blob+=$(cat 2>/dev/null || true)
fi

# Account-level rate-limit signals emitted by claude-code-action / the Claude Code CLI
# when the subscription pool's five-hour window is exhausted mid-review (see #236 evidence:
# runs 29461363906 / 29460963697). Match the structured event type and the typed
# five-hour limit; either is a strong, specific account-limit signal. `resetsAt` alone is
# intentionally NOT sufficient (too generic) — it must co-occur with a rate-limit marker.
if printf '%s' "$blob" | grep -Eiq 'rate_limit_event|"?rateLimitType"?[[:space:]]*:[[:space:]]*"?five_hour|usage[_ ]?limit_reached'; then
  emit infra
fi

emit fail-closed
