#!/usr/bin/env bash
#
# Shared live hold/keep re-check (#461).
#
# #454 fixed pr-unstick.yml's needs-human and security-review-retry sweeps to re-read a
# PR's labels immediately before mutating it, instead of acting on a snapshot taken once
# at the top of a (multi-minute, many-gh-call) loop — the reachability sweep already had
# this pattern. Three near-identical inline copies of "gh pr view --json labels; skip if
# hold/keep present" is exactly the repeated-bug-class shape gh-list-exhaustive was
# extracted for (CLAUDE.md); this is the same fix for this bug class.
#
# Usage: check-live-hold-keep.sh <pr-number>
# Env:   GH_TOKEN, GH_REPO must already be set by the caller.
# Prints exactly one word to stdout and always exits 0 (never fails the caller's step):
#   clear         - fetched labels successfully, neither hold nor keep present
#   blocked       - fetched labels successfully, hold and/or keep present
#   fetch-failed  - could not re-fetch live labels; caller should skip rather than
#                   act on a stale snapshot
set -uo pipefail

n="${1:?usage: check-live-hold-keep.sh <pr-number>}"

if ! live_labels=$(gh pr view "$n" --json labels --jq '[.labels[].name]' 2>/dev/null); then
  echo "fetch-failed"
  exit 0
fi

if echo "$live_labels" | jq -e '(index("hold") or index("keep"))' >/dev/null 2>&1; then
  echo "blocked"
else
  echo "clear"
fi
