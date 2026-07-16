#!/usr/bin/env bash
# Regression guard for an audit-confirmed cross-repo pipeline defect:
#   scaffold-caller.sh's security-review template must emit `ready_for_review`
#   in its pull_request types, or a newly-scaffolded repo's review silently
#   never re-runs when a draft PR is marked ready (GitHub counts a skipped
#   required check as passing).
#
# (The HIGH_BLAST_RE high-blast/trusted-author no-verdict classification this
# script used to test was removed from security-review.yml: a missing verdict
# is now an unconditional advisory pass, never a fail-closed `hold`, regardless
# of what the diff touches — see the "Gate — advisory pass on missing verdict"
# step's comment for why.)
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

echo "[1/1] scaffold-caller.sh's security-review template includes ready_for_review"
stub=$(awk '/^emit security-review <<YAML/,/^YAML$/' scripts/scaffold-caller.sh)
if printf '%s\n' "$stub" | grep -q 'ready_for_review'; then
  note "generated security-review stub includes ready_for_review"
else
  bad "scaffold-caller.sh's security-review template omits ready_for_review — a newly-scaffolded repo's required security gate will silently never re-run when a draft PR goes ready (GitHub counts a skipped required check as passing)"
fi

[ "$fail" -eq 0 ] && { echo "scaffold-caller regression guard: PASS"; exit 0; } || { echo "scaffold-caller regression guard: FAIL"; exit 1; }
