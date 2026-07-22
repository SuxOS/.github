#!/usr/bin/env bash
# Shared marker-comment cycle-tracking reader (SuxOS/.github#589). Extracts the
# "fetch all comments, find the last one whose body starts with a marker prefix, parse
# cycle=N off it" idiom pr-unstick.yml's PR-side retry ladder and issue-build.yml's
# issue-side drop-escalation ladder each hand-rolled independently (~25-30 lines apiece).
# See action.yml in this directory for why this exists and the two ways it's invoked: as
# this action's own `uses:` step, or checked out and called directly inside a bash loop (a
# `uses:` step can't run mid-loop) — same file either way, so the logic can't drift out of
# sync between call sites the way the pre-#589 duplicated inline copies did.
set -uo pipefail

repo="${1:?usage: read-cycle.sh <owner/repo> <item-number> <marker-prefix>}"
n="${2:?usage: read-cycle.sh <owner/repo> <item-number> <marker-prefix>}"
marker="${3:?usage: read-cycle.sh <owner/repo> <item-number> <marker-prefix>}"

ok="true"
cycle=0
comment_id=""
last_at_epoch=0

if ! comments=$(gh api "repos/${repo}/issues/${n}/comments" --paginate 2>/dev/null); then
  echo "::warning::could not fetch comments for ${repo}#${n} — treating cycle count as 0 rather than failing the caller" >&2
  ok="false"
else
  found=$(echo "$comments" | jq -c --arg m "$marker" '[.[] | select(.body | startswith($m))] | last' 2>/dev/null || echo 'null')
  if [ "$found" != "null" ] && [ -n "$found" ]; then
    comment_id=$(echo "$found" | jq -r '.id' 2>/dev/null || true)
    body=$(echo "$found" | jq -r '.body' 2>/dev/null || true)
    cycle=$(echo "$body" | grep -oE 'cycle=[0-9]+' | head -1 | cut -d= -f2 || true)
    cycle=${cycle:-0}
    last_at=$(echo "$body" | grep -oE 'at=[0-9TZ:-]+' | head -1 | cut -d= -f2 || true)
    last_at_epoch=$(date -u -d "${last_at:-}" +%s 2>/dev/null || echo 0)
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "ok=$ok"
    echo "cycle=$cycle"
    echo "comment_id=$comment_id"
    echo "last_at_epoch=$last_at_epoch"
  } >> "$GITHUB_OUTPUT"
fi

# Plain key=value lines on stdout, one per line, numeric/id values only (no untrusted
# free text) — safe for a direct-call caller to `eval "$(bash read-cycle.sh ...)"`.
printf 'ok=%s\ncycle=%s\ncomment_id=%s\nlast_at_epoch=%s\n' "$ok" "$cycle" "$comment_id" "$last_at_epoch"
