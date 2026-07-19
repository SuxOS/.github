#!/usr/bin/env bash
# Shared PR live hold/keep re-check (SuxOS/.github#461). See action.yml in this
# directory for why this exists and the two ways it's invoked: as this action's own
# `uses:` step, or checked out and called directly inside a bash loop (a `uses:` step
# can't run mid-loop) — same file either way, so the check can't drift out of sync
# between call sites the way the pre-#454 duplicated inline copies did.
set -uo pipefail

n="${1:?usage: check.sh <pr-number>}"
hold="true"
reason=""

if ! live_labels=$(gh pr view "$n" --json labels --jq '[.labels[].name]' 2>/dev/null); then
  echo "::warning::could not re-fetch live labels for PR #$n — treating as held rather than acting on a stale snapshot" >&2
  reason="fetch-failed"
elif echo "$live_labels" | jq -e '(index("hold") or index("keep"))' >/dev/null 2>&1; then
  echo "#$n now has hold/keep (added since the sweep's candidate list was fetched) — leaving to the operator" >&2
  reason="hold-keep"
else
  hold="false"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "hold=$hold"
    echo "reason=$reason"
  } >> "$GITHUB_OUTPUT"
fi

echo "$hold"
