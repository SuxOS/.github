#!/usr/bin/env bash
# Shared marker-comment cycle-tracking writer (SuxOS/.github#589) — the upsert half of
# marker-cycle-read's idiom. Builds `<!-- prefix: cycle=N at=<now> -->` + a summary line,
# then PATCHes the existing marker comment if one was found (comment-id non-empty) or POSTs
# a new one. Issue and PR comments share the same `issues/{n}/comments` REST endpoint, so
# this one script covers both callers regardless of whether item-number is an issue or PR.
set -uo pipefail

repo="${1:?usage: upsert-cycle.sh <owner/repo> <item-number> <marker-prefix> <next-cycle> <comment-id-or-empty> <summary-line>}"
n="${2:?usage: upsert-cycle.sh <owner/repo> <item-number> <marker-prefix> <next-cycle> <comment-id-or-empty> <summary-line>}"
marker="${3:?usage: upsert-cycle.sh <owner/repo> <item-number> <marker-prefix> <next-cycle> <comment-id-or-empty> <summary-line>}"
next_cycle="${4:?usage: upsert-cycle.sh <owner/repo> <item-number> <marker-prefix> <next-cycle> <comment-id-or-empty> <summary-line>}"
comment_id="${5:-}"
summary="${6:?usage: upsert-cycle.sh <owner/repo> <item-number> <marker-prefix> <next-cycle> <comment-id-or-empty> <summary-line>}"

marker_line="${marker} cycle=${next_cycle} at=$(date -u +%Y-%m-%dT%H:%M:%SZ) -->"
new_body="$(printf '%s\n%s' "$marker_line" "$summary")"

if [ -n "$comment_id" ]; then
  gh api "repos/${repo}/issues/comments/${comment_id}" -X PATCH -f body="$new_body" >/dev/null 2>&1 \
    || echo "::warning::could not update the marker comment on ${repo}#${n}" >&2
else
  gh api "repos/${repo}/issues/${n}/comments" -f body="$new_body" >/dev/null 2>&1 \
    || echo "::warning::could not post the marker comment on ${repo}#${n}" >&2
fi
