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
# SPOOF RESISTANCE (SuxOS/.github#271 review, high finding): the signal is matched
# STRUCTURALLY, never as a substring of free text. The execution log is stream-json — an
# array (or JSONL) of message objects. A genuine account rate-limit is a top-level message
# object `{"type":"rate_limit_event","rate_limit_info":{...}}` (see the Claude Agent SDK
# message parser: rate_limit_event carries a `rate_limit_info` with rateLimitType/resetsAt).
# Attacker-controlled diff/tool output is only ever captured as STRING VALUES inside message
# `content`/`stdout` fields — a string is never a dict, so it can never present `type` and a
# structured `rate_limit_info` as real object keys. We walk the PARSED JSON and require BOTH
# a `type == "rate_limit_event"` AND a dict `rate_limit_info`; we never re-parse string values
# as JSON and never grep raw text. A PR that embeds the literal `rate_limit_event` in its diff
# therefore classifies `fail-closed`, not `infra` — closing the evasion path.
#
# Contract:
#   - Args: zero or more paths to claude-code-action `execution_file` outputs (JSON logs).
#     Missing/empty/unreadable/unparseable files are ignored (treated as "no signal").
#   - Also reads stdin if piped (lets unit tests feed synthetic stream-json without temp files).
#   - Prints exactly one classification token to stdout and exits 0:
#       infra        -> genuine account rate-limit event object present. NOT diff-controllable.
#                       Caller emits a non-passing, AUTO-REQUEUED outcome (block this run, no
#                       `hold`, re-run after the limit resets).
#       fail-closed  -> no such event. The reviewer ran but emitted nothing usable on THIS
#                       diff (refusal, looping, max-turns/timeout) — the evasion vector.
#                       Caller FAILS CLOSED (`hold` + block).
#
# SECURITY INVARIANT: the only path that yields `infra` is a genuine, STRUCTURED
# account-level rate-limit event. Any ambiguity, unreadable/unparseable input, or internal
# error -> `fail-closed`. A crash must never be read as "infra, don't block".
set -uo pipefail

# A hard error in this classifier itself must never ungate: default to fail-closed.
trap 'printf "fail-closed\n"; exit 0' ERR

# Collect readable file args (missing/empty ignored) and note whether stdin is piped, then
# hand everything to a structural JSON walk in python3 (present on ubuntu-latest runners and
# locally). python does the parsing; bash never inspects the log text.
have_stdin=0
[ -t 0 ] || have_stdin=1

# The python program is fed via a process-substitution FD (not `python3 - <<EOF`, which
# would consume python's stdin via the heredoc and hide the piped log). Real stdin stays
# connected so `sys.stdin.read()` sees the piped execution log in tests / at runtime.
read -r -d '' PYPROG <<'PY' || true
import json, os, sys

def is_rate_limit_event(obj):
    """True iff a genuine, STRUCTURED account rate-limit message object is present.

    Walks only parsed dict/list structure — never treats a string value as JSON — so
    attacker-controlled diff/tool text (always a string value) can't forge the signal.
    """
    stack = [obj]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            if cur.get("type") == "rate_limit_event" and isinstance(cur.get("rate_limit_info"), dict):
                return True
            stack.extend(cur.values())
        elif isinstance(cur, list):
            stack.extend(cur)
        # strings/numbers/None: ignore — never re-parsed as JSON
    return False

def scan(text):
    if not text or not text.strip():
        return False
    # Whole-document parse first (execution_file is a JSON array or object).
    try:
        if is_rate_limit_event(json.loads(text)):
            return True
    except (ValueError, TypeError):
        pass
    # Fallback: JSONL — one message object per line. A line that doesn't parse is skipped,
    # NOT grepped as text (that would reintroduce the substring-spoof vulnerability).
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            continue
        if is_rate_limit_event(obj):
            return True
    return False

texts = []
for path in sys.argv[1:]:
    if path and os.path.isfile(path) and os.access(path, os.R_OK):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                texts.append(fh.read())
        except OSError:
            continue
if os.environ.get("HAVE_STDIN") == "1":
    try:
        texts.append(sys.stdin.read())
    except OSError:
        pass

print("infra" if any(scan(t) for t in texts) else "fail-closed")
PY

result=$(HAVE_STDIN="$have_stdin" python3 <(printf '%s' "$PYPROG") "$@") || result="fail-closed"

case "$result" in
  infra) printf 'infra\n' ;;
  *)     printf 'fail-closed\n' ;;
esac
exit 0
