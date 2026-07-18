#!/usr/bin/env bash
# Guards against a NEW bespoke `gh <issue|pr|run|workflow> list ... --limit` call site
# (SuxOS/.github#431).
#
# The client-side-filtered undercount bug class ("gh ... list --limit N then filter"
# silently dropping results past the cap) was fixed ad hoc at least six times (#18,
# #247, #344, #345, #350, #366) before .github/actions/gh-list-exhaustive was built to
# stop it recurring. CLAUDE.md says to prefer it over a new bespoke bounded list call,
# but only flood-guard has actually migrated so far — 17+ other bare call sites remain
# as a deliberate, tracked deferral. This script doesn't force those migrations; it
# just closes the loop so a NEW PR can't quietly add another one: any `gh ... list
# ... --limit` site not already on the allowlist below (or inside gh-list-exhaustive
# itself) fails the gate.
#
# Not a full parser — this is a grep-based invariant, same spirit as
# test-dashboard-queries.sh isn't a full PromQL linter. It matches on file + a snippet
# of the actual invocation text, not line number, so unrelated line-shifting edits in
# an allowlisted file don't spuriously fail this gate.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)

fail=0

# Each entry: "path::snippet" — snippet is a substring of the matched line unique
# enough to identify that specific call site. These are the sites CLAUDE.md and
# SuxOS/.github#431 already track as deliberately-deferred bespoke bounded calls (or,
# for a few, prose in a Claude prompt referencing `gh issue list --limit N` for dedup
# guidance rather than an actual bounded shell call).
ALLOWLIST=(
  ".github/workflows/pr-drain.yml::gh pr list --state open --limit \"\$PR_LIMIT\""
  ".github/workflows/pr-watch.yml::gh pr list --repo \"\$GITHUB_REPOSITORY\" --state open --limit \"\$PR_LIMIT\""
  ".github/workflows/issue-build.yml::gh issue list --state open --limit 300"
  ".github/workflows/org-consistency.yml::gh issue list --limit 200 --state all"
  ".github/workflows/budget-governor.yml::gh run list --repo \"SuxOS/\$r\" --limit 1000 --created"
  ".github/workflows/budget-governor.yml::gh run list --repo \"SuxOS/\$r\" --limit 50 --created"
  ".github/workflows/fabric-health.yml::gh issue list --repo \"\$slug\" --state open --limit 201"
  ".github/workflows/fabric-health.yml::gh pr list --repo \"\$slug\" --state open --limit 201"
  ".github/workflows/fabric-health.yml::gh workflow list --repo \"\$slug\" --all --limit 101"
  ".github/workflows/fabric-health.yml::gh run list --limit 200"
  ".github/workflows/fabric-health.yml::gh run list --repo \"\$slug\" --limit 100"
  ".github/workflows/fabric-health.yml::gh run list --repo \"\$slug\" --workflow \"\$wf_id\" --limit 1"
  ".github/workflows/deep-audit.yml::gh issue list --limit 200 --state all"
  ".github/workflows/pr-unstick.yml::gh pr list --state open --label needs-human --limit \"\$PR_LIMIT\""
  ".github/workflows/pr-unstick.yml::gh run list --repo \"\$GH_REPO\" --commit \"\$sha\" --limit 100 --json databaseId,conclusion"
  ".github/workflows/pr-unstick.yml::gh pr list --state open --label security-review-retry --limit \"\$PR_LIMIT\""
  ".github/workflows/pr-unstick.yml::gh run list --repo \"\$GH_REPO\" --commit \"\$sha\" --limit 100 \\"
  ".github/actions/check-throttle/action.yml::gh issue list --repo \"\$REPO\" --state open --search"
  ".github/actions/detect-unreachable-checks/check.sh::gh pr list --state open --limit \"\$pr_limit\""
  ".github/workflows/fixer.yml::gh issue list --limit 300 --state all"
  ".github/workflows/pr-auto-update.yml::A bounded \`gh pr list --limit N\`"
  ".github/actions/upsert-tracking-issue/action.yml::gh issue list --repo \"\$REPO\" --state open --limit \"\$limit\""
)

is_allowlisted() {
  local path="$1" line="$2" entry entry_path entry_snippet
  for entry in "${ALLOWLIST[@]}"; do
    entry_path="${entry%%::*}"
    entry_snippet="${entry#*::}"
    [ "$entry_path" = "$path" ] || continue
    case "$line" in
      *"$entry_snippet"*) return 0 ;;
    esac
  done
  return 1
}

while IFS=: read -r file lineno content; do
  [ -z "$file" ] && continue
  case "$file" in
    .github/actions/gh-list-exhaustive/*) continue ;;
  esac
  if is_allowlisted "$file" "$content"; then
    continue
  fi
  echo "FAIL: $file:$lineno: new bespoke 'gh ... list ... --limit' call site not on the allowlist" >&2
  echo "        $content" >&2
  echo "        Prefer .github/actions/gh-list-exhaustive (CLAUDE.md), or if this bounded call" >&2
  echo "        is genuinely intentional, add it to ALLOWLIST in $0." >&2
  fail=1
done < <(grep -rnE 'gh (issue|pr|run|workflow) list\b[^|]*--limit' .github/workflows .github/actions 2>/dev/null)

if [ "$fail" -eq 0 ]; then
  echo "ok: no new bespoke 'gh ... list --limit' call sites outside the tracked allowlist"
else
  echo
  echo "gh-list-limit allowlist check failed"
fi
exit "$fail"
