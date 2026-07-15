#!/usr/bin/env bash
# Regression guard for two audit-confirmed cross-repo pipeline defects:
#   1. security-review.yml's no-verdict fail-closed classification must treat
#      .github/actions/ (composite actions, incl. the App-token minter and the
#      auto-merge gate itself) as high-blast, same as .github/workflows/.
#   2. scaffold-caller.sh's security-review template must emit `ready_for_review`
#      in its pull_request types, or a newly-scaffolded repo's review silently
#      never re-runs when a draft PR is marked ready (GitHub counts a skipped
#      required check as passing).
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

echo "[1/2] security-review.yml high-blast pattern covers .github/actions/"
# The pattern now lives in a single HIGH_BLAST_RE='...' assignment (used by both the
# classify grep and the offender-print grep, so they can't drift). Extract it from there.
pattern=$(grep -oE "HIGH_BLAST_RE='[^']+'" .github/workflows/security-review.yml | head -1 | sed "s/^HIGH_BLAST_RE='//; s/'\$//")
if [ -z "$pattern" ]; then
  bad "could not extract HIGH_BLAST_RE from security-review.yml — has the assignment moved/changed shape?"
else
  for probe in \
    ".github/actions/mint-app-token/action.yml" \
    ".github/actions/assert-branch-protection/action.yml" \
    ".github/workflows/security-review.yml" \
    ".github/scripts/scaffold-caller.sh"; do
    if printf '%s\n' "$probe" | grep -qiE "$pattern"; then
      note "$probe classified high-blast"
    else
      bad "$probe should be high-blast (control-surface path) but the pattern misses it: /$pattern/"
    fi
  done
  # negative controls: ordinary source files must NOT be high-blast (proves the pattern
  # isn't just matching everything). Includes the substring false-positives the pattern was
  # tightened to exclude — auth|secret are delimiter-bounded tokens, so `author`/`secretary`/
  # `oauthor` must NOT trip a spurious fail-closed hold.
  for clean in \
    "sux/src/fns/amazon.ts" \
    "src/authors/list.ts" \
    "docs/secretary-notes.md" \
    "lib/oauthor.ts"; do
    if printf '%s\n' "$clean" | grep -qiE "$pattern"; then
      bad "ordinary path '$clean' matched the high-blast pattern — too broad: /$pattern/"
    else
      note "$clean correctly NOT high-blast"
    fi
  done
  # positive control for the tightened token: real auth/secret files MUST still classify.
  for sensitive in "src/auth/mw.ts" "config/secrets.yaml" "lib/oauth.ts"; do
    if printf '%s\n' "$sensitive" | grep -qiE "$pattern"; then
      note "$sensitive correctly high-blast"
    else
      bad "sensitive path '$sensitive' should be high-blast but the pattern misses it: /$pattern/"
    fi
  done
fi

echo "[2/2] scaffold-caller.sh's security-review template includes ready_for_review"
stub=$(awk '/^emit security-review <<YAML/,/^YAML$/' scripts/scaffold-caller.sh)
if printf '%s\n' "$stub" | grep -q 'ready_for_review'; then
  note "generated security-review stub includes ready_for_review"
else
  bad "scaffold-caller.sh's security-review template omits ready_for_review — a newly-scaffolded repo's required security gate will silently never re-run when a draft PR goes ready (GitHub counts a skipped required check as passing)"
fi

[ "$fail" -eq 0 ] && { echo "pipeline invariants: PASS"; exit 0; } || { echo "pipeline invariants: FAIL"; exit 1; }
