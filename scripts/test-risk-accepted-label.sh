#!/usr/bin/env bash
# Unit-tests the owner risk-acceptance validator (scripts/check-risk-accepted.sh) —
# the label-bypass path in security-review.yml's Gate. No network, no live gh: a fake
# `gh` shim on PATH serves canned API responses controlled per-case via env vars.
#
# INVARIANT under test: `accepted` is returned ONLY when the latest
# security-risk-accepted label event is `labeled`, by a HUMAN admin, at/after the head
# SHA's first check-suite timestamp. Everything else — no label, revoked label, bot
# applier, non-admin applier, stale (pre-push) label, unreadable timeline/permission/
# check-suite API — MUST return `not-accepted`. A regression flipping any of those to
# `accepted` turns a required security gate into a triage-level bypass.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root
SCRIPT="$(pwd)/scripts/check-risk-accepted.sh"
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

# ── fake gh shim ──────────────────────────────────────────────────────────────────
# Dispatches on the api path substring; responses come from FAKE_* env vars. An
# empty FAKE_* means "API call fails" (exit 1, no output) — the fail-closed paths.
SHIMDIR=$(mktemp -d)
trap 'rm -rf "$SHIMDIR"' EXIT
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"/timeline"*)
    [ -n "${FAKE_TIMELINE:-}" ] || exit 1
    printf '%s' "$FAKE_TIMELINE" ;;
  *"/collaborators/"*"/permission"*)
    [ -n "${FAKE_PERM:-}" ] || exit 1
    printf '%s\n' "$FAKE_PERM" ;;
  *"/check-suites"*)
    [ -n "${FAKE_SUITE_AT:-}" ] || exit 1
    printf '%s\n' "$FAKE_SUITE_AT" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$SHIMDIR/gh"
export PATH="$SHIMDIR:$PATH"

run_case() {
  local name="$1" want="$2" got
  got=$(GITHUB_REPOSITORY="SuxOS/testrepo" bash "$SCRIPT" 42 deadbeef 2>/dev/null)
  if [ "$got" = "$want" ]; then note "[$name] -> $got"; else bad "[$name] expected '$want', got '$got'"; fi
}

# Timeline payloads are the --paginate --slurp shape: an ARRAY OF PAGES.
LABELED_ADMIN='[[{"event":"labeled","label":{"name":"security-risk-accepted"},"actor":{"login":"colinxs"},"created_at":"2026-07-22T12:00:00Z"}]]'
LABELED_THEN_REMOVED='[[{"event":"labeled","label":{"name":"security-risk-accepted"},"actor":{"login":"colinxs"},"created_at":"2026-07-22T12:00:00Z"},{"event":"unlabeled","label":{"name":"security-risk-accepted"},"actor":{"login":"colinxs"},"created_at":"2026-07-22T12:05:00Z"}]]'
LABELED_BY_BOT='[[{"event":"labeled","label":{"name":"security-risk-accepted"},"actor":{"login":"suxbot[bot]"},"created_at":"2026-07-22T12:00:00Z"}]]'
OTHER_LABEL_ONLY='[[{"event":"labeled","label":{"name":"hold"},"actor":{"login":"colinxs"},"created_at":"2026-07-22T12:00:00Z"}]]'
RELABELED_FRESH='[[{"event":"labeled","label":{"name":"security-risk-accepted"},"actor":{"login":"colinxs"},"created_at":"2026-07-22T09:00:00Z"},{"event":"unlabeled","label":{"name":"security-risk-accepted"},"actor":{"login":"colinxs"},"created_at":"2026-07-22T09:30:00Z"},{"event":"labeled","label":{"name":"security-risk-accepted"},"actor":{"login":"colinxs"},"created_at":"2026-07-22T12:00:00Z"}]]'

echo "[1] admin-applied label after head's first check-suite -> accepted"
FAKE_TIMELINE="$LABELED_ADMIN" FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "happy-path" accepted

echo "[2] label never applied -> not-accepted"
FAKE_TIMELINE='[[]]' FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "no-label" not-accepted

echo "[3] only unrelated labels present -> not-accepted"
FAKE_TIMELINE="$OTHER_LABEL_ONLY" FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "other-label" not-accepted

echo "[4] label applied then removed (revoked) -> not-accepted"
FAKE_TIMELINE="$LABELED_THEN_REMOVED" FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "revoked" not-accepted

echo "[5] label applied by a [bot] actor -> not-accepted"
FAKE_TIMELINE="$LABELED_BY_BOT" FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "bot-applier" not-accepted

echo "[6] label applied by a non-admin (write) -> not-accepted"
FAKE_TIMELINE="$LABELED_ADMIN" FAKE_PERM=write FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "non-admin" not-accepted

echo "[7] STALE: label predates this head's first check-suite (new push after acceptance) -> not-accepted"
FAKE_TIMELINE="$LABELED_ADMIN" FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T13:00:00Z" run_case "stale-label" not-accepted

echo "[8] re-applied after revocation, fresh vs suite -> accepted (latest event wins)"
FAKE_TIMELINE="$RELABELED_FRESH" FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "relabel-fresh" accepted

echo "[9] timeline API unreadable -> not-accepted (fail closed)"
FAKE_TIMELINE="" FAKE_PERM=admin FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "timeline-error" not-accepted

echo "[10] permission API unreadable -> not-accepted (fail closed)"
FAKE_TIMELINE="$LABELED_ADMIN" FAKE_PERM="" FAKE_SUITE_AT="2026-07-22T11:00:00Z" run_case "perm-error" not-accepted

echo "[11] no check-suite anchor for head SHA -> not-accepted (fail closed)"
FAKE_TIMELINE="$LABELED_ADMIN" FAKE_PERM=admin FAKE_SUITE_AT="" run_case "no-suite" not-accepted

echo "[12] missing args -> not-accepted (fail closed)"
got=$(GITHUB_REPOSITORY="" bash "$SCRIPT" "" "" 2>/dev/null)
if [ "$got" = "not-accepted" ]; then note "[missing-args] -> $got"; else bad "[missing-args] expected 'not-accepted', got '$got'"; fi

if [ "$fail" -eq 0 ]; then echo "test-risk-accepted-label: all cases passed"; else echo "test-risk-accepted-label: FAILURES" >&2; exit 1; fi
