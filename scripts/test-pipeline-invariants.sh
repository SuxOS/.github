#!/usr/bin/env bash
# Regression guard for two audit-confirmed cross-repo pipeline defects:
#   1. security-review.yml's no-verdict fail-closed classification must treat
#      .github/actions/ (composite actions, incl. the App-token minter and the
#      auto-merge gate itself) as high-blast, same as .github/workflows/.
#   2. scaffold-caller.sh's security-review template must emit `ready_for_review`
#      in its pull_request types, or a newly-scaffolded repo's review silently
#      never re-runs when a draft PR is marked ready (GitHub counts a skipped
#      required check as passing).
# Run from repo root: bash .github/scripts/test-pipeline-invariants.sh
set -euo pipefail
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

echo "[1/2] security-review.yml high-blast pattern covers .github/actions/"
pattern=$(grep -oE "grep -qiE '[^']+'" .github/.github/workflows/security-review.yml | head -1 | sed "s/^grep -qiE '//; s/'\$//")
if [ -z "$pattern" ]; then
  bad "could not extract the high-blast grep pattern from security-review.yml — has the line moved/changed shape?"
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
  # negative control: an ordinary source file must NOT be high-blast (proves the
  # pattern isn't just matching everything, which would defeat the point of it)
  if printf '%s\n' "sux/src/fns/amazon.ts" | grep -qiE "$pattern"; then
    bad "an ordinary source path matched the high-blast pattern — pattern is too broad: /$pattern/"
  else
    note "ordinary source path correctly NOT high-blast (pattern isn't overbroad)"
  fi
fi

echo "[2/2] scaffold-caller.sh's security-review template includes ready_for_review"
stub=$(awk '/^emit security-review <<YAML/,/^YAML$/' .github/scripts/scaffold-caller.sh)
if printf '%s\n' "$stub" | grep -q 'ready_for_review'; then
  note "generated security-review stub includes ready_for_review"
else
  bad "scaffold-caller.sh's security-review template omits ready_for_review — a newly-scaffolded repo's required security gate will silently never re-run when a draft PR goes ready (GitHub counts a skipped required check as passing)"
fi

[ "$fail" -eq 0 ] && { echo "pipeline invariants: PASS"; exit 0; } || { echo "pipeline invariants: FAIL"; exit 1; }
