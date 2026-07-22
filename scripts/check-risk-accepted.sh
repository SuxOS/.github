#!/usr/bin/env bash
# Validate an OWNER RISK-ACCEPTANCE of security-review findings via the
# `security-risk-accepted` label, so the Gate step in security-review.yml can
# advisory-pass a verdict with confirmed high/critical findings that the repo
# owner has explicitly accepted — instead of forcing an --admin merge over a
# permanently-red required check (the only prior escape hatch; see
# claude-config#427, where the reviewer itself scored the finding "transparently
# documented owner risk-acceptance" yet the gate could never go green).
#
# A bare label is NOT enough — labels can be applied by anyone with triage and
# they stick across new pushes. Acceptance is valid ONLY when ALL hold:
#   1. The LATEST `security-risk-accepted` labeled/unlabeled timeline event for
#      the PR is `labeled` (an unlabel after the fact revokes acceptance).
#   2. That event's actor is a HUMAN (no `[bot]` suffix) with ADMIN permission
#      on the repo — checked live via the collaborators API, never inferred.
#   3. The label was applied AT OR AFTER the first check-suite created for the
#      PR's CURRENT head SHA (server-stamped, not the spoofable commit date) —
#      i.e. the admin labeled after this exact diff's checks began, so the
#      acceptance covers findings on THIS push, not an earlier one. A new push
#      mints a new first-suite timestamp and silently STALES the old label.
#
# Contract:
#   - Args: PR_NUMBER HEAD_SHA [OWNER/REPO (default: $GITHUB_REPOSITORY)]
#   - Env:  GH_TOKEN (for gh api)
#   - Prints exactly one token to stdout and exits 0:
#       accepted      -> all three conditions verified
#       not-accepted  -> anything else
#     The reason is logged to stderr either way.
#
# SECURITY INVARIANT: fail closed. Any missing arg, unreadable API response,
# bot/non-admin actor, revoked label, missing check-suite anchor, or internal
# error -> `not-accepted`. A crash must never be read as acceptance.
set -uo pipefail

LABEL="security-risk-accepted"
PR="${1:-}"
SHA="${2:-}"
REPO="${3:-${GITHUB_REPOSITORY:-}}"

say() { echo "check-risk-accepted: $*" >&2; }
no()  { say "not-accepted: $*"; echo "not-accepted"; exit 0; }

[ -n "$PR" ] && [ -n "$SHA" ] && [ -n "$REPO" ] || no "missing PR/SHA/repo args"
command -v jq >/dev/null 2>&1 || no "jq not available"

# ── 1. latest labeled/unlabeled event for the acceptance label ──────────────────
# --paginate --slurp wraps pages as array-of-arrays (even one empty page is [[]]),
# so flatten with `add // []` (see CLAUDE.md's gh --paginate gotcha).
events=$( { gh api "repos/$REPO/issues/$PR/timeline?per_page=100" --paginate --slurp 2>/dev/null; } || true)
[ -n "$events" ] || no "could not read PR timeline"
last=$( { printf '%s' "$events" | jq -c --arg L "$LABEL" \
  '(add // []) | map(select((.event == "labeled" or .event == "unlabeled") and ((.label.name // "") == $L))) | last // empty' \
  2>/dev/null; } || true)
[ -n "$last" ] || no "label '$LABEL' has never been applied to PR #$PR"
last_event=$( { printf '%s' "$last" | jq -r '.event // ""' 2>/dev/null; } || true)
[ "$last_event" = "labeled" ] || no "label '$LABEL' was removed (latest event: '${last_event:-unknown}') — acceptance revoked"

# ── 2. actor must be a human repo admin ─────────────────────────────────────────
actor=$( { printf '%s' "$last" | jq -r '.actor.login // ""' 2>/dev/null; } || true)
label_at=$( { printf '%s' "$last" | jq -r '.created_at // ""' 2>/dev/null; } || true)
[ -n "$actor" ] && [ -n "$label_at" ] || no "label event is missing actor or timestamp"
case "$actor" in
  *"[bot]") no "label applied by bot actor '$actor' — only a human admin's application counts" ;;
esac
perm=$( { gh api "repos/$REPO/collaborators/$actor/permission" -q '.permission' 2>/dev/null; } || true)
[ "$perm" = "admin" ] || no "label applier '$actor' has repo permission '${perm:-unreadable}' — admin required"

# ── 3. freshness: labeled at/after this head SHA's first check-suite ────────────
# Both timestamps are GitHub-server ISO8601 UTC (...Z), so lexicographic compare
# is chronological compare. The first check-suite's created_at is server-stamped
# at push/PR-sync time — unlike the commit's own dates, it cannot be backdated by
# the PR author, so a post-acceptance push can never inherit the old acceptance.
suite_at=$( { gh api "repos/$REPO/commits/$SHA/check-suites?per_page=100" \
  -q '[.check_suites[].created_at] | sort | first // ""' 2>/dev/null; } || true)
[ -n "$suite_at" ] || no "no check-suite found for head $SHA — cannot anchor label freshness"
if [[ "$label_at" < "$suite_at" ]]; then
  no "label applied at $label_at, before this head's first check-suite at $suite_at — stale acceptance from an earlier push; review the CURRENT findings, then re-apply the label"
fi

say "accepted: '$actor' (admin) applied '$LABEL' at $label_at >= head $SHA first-suite $suite_at"
echo "accepted"
