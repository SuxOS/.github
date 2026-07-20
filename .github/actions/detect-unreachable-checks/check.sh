#!/usr/bin/env bash
# Decision logic for "detect required contexts that can never report on a PR
# head" (SuxOS/.github#323). Kept in its own file (rather than inline in
# action.yml) so scripts/test-detect-unreachable-checks.sh can exercise it
# directly against a mocked `gh`, with no network.
#
# Scans every open, non-draft PR against the CURRENT repo. For each PR's base
# branch, reads required contexts from /rules/branches/<base> ONLY (classic
# /branches/*/protection 404s org-wide for the App token — see
# assert-branch-protection/check.sh) and diffs them against what has actually
# reported on the PR's head SHA. A context in required-but-never-reported is a
# PR that is permanently blocked with no failing check to fix.
#
# Detects and explains only — never mutates a PR, never reruns/updates
# anything (that's pr-unstick.yml's other jobs). Exits 1 only if it found a
# real never-reporting context on at least one settled PR, so the run shows
# red in the Actions UI without gating any merge (this workflow isn't a
# required check). Every other path (unreadable rulesets, unsettled CI, a
# fresh commit inside the grace window) fails safe: warn/log and move on,
# never fabricating a jam out of an API blip or a normal in-flight PR.
set -uo pipefail

grace_minutes="${GRACE_MINUTES:-30}"
if ! [[ "$grace_minutes" =~ ^[0-9]+$ ]]; then grace_minutes=30; fi
grace_sec=$(( grace_minutes * 60 ))
pr_limit="${PR_LIMIT:-50}"

# segment-boundary match, mirroring assert-branch-protection/check.sh: a
# required context can be a trailing " / "-delimited segment of a live check
# name (job-name-prefix drift) but a merely superset-named check must not
# count as reachable (same #210 hole that action already closed).
context_reachable() {
  local gate="$1" reported="$2" ctx
  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    if [ "$ctx" = "$gate" ] || [ "${ctx%" / $gate"}" != "$ctx" ]; then
      return 0
    fi
  done <<< "$reported"
  return 1
}

if ! prs=$(gh pr list --state open --limit "$pr_limit" \
  --json number,isDraft,baseRefName,headRefOid \
  --jq '[.[] | select(.isDraft | not)]' 2>/dev/null); then
  echo "::warning::gh pr list failed — cannot enumerate open PRs, skipping reachability check this run (an API blip must not be reported as a jam)"
  exit 0
fi
count=$(echo "$prs" | jq 'length')
echo "open non-draft PRs to check: $count"
# gh pr list returns created-desc with no label to narrow by here (every open PR is in
# scope), so hitting the cap means the OLDEST open PRs — exactly the ones most likely to
# be stuck — silently fell off this run (SuxOS/.github#366). Surface it instead of staying
# quiet the way a plain truncation would.
if [ "$count" -eq "$pr_limit" ]; then
  echo "::warning::open PR count hit pr-limit ($pr_limit) — oldest open PRs beyond the cap were not checked this run"
fi
if [ "$count" -eq 0 ]; then exit 0; fi

declare -A required_cache
declare -A readable_cache
found_any=0
# PRs whose ONLY never-reporting cause is generic (not a disabled workflow) —
# i.e. path-filtered required workflow or onboarding-window, the two causes
# pr-unstick.yml's reachability sweep (SuxOS/.github#379) can safely retry
# with an empty commit. A PR with even one disabled-workflow cause is left
# out here: that has its own remedy (re-enable the workflow), not a push.
declare -a generic_prs=()
workflows_json=""
workflows_fetch_failed=0

for row in $(echo "$prs" | jq -c '.[]'); do
  n=$(echo "$row" | jq -r '.number')
  base=$(echo "$row" | jq -r '.baseRefName')
  sha=$(echo "$row" | jq -r '.headRefOid')
  echo "::group::PR #$n (base=$base head=$sha)"

  if [ -z "${readable_cache[$base]+x}" ]; then
    if rules=$(gh api "repos/${GH_REPO}/rules/branches/${base}" 2>/dev/null); then
      readable_cache[$base]=1
      required_cache[$base]=$(printf '%s' "$rules" \
        | jq -r '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | .[]' 2>/dev/null \
        | sed 's/^ *//' | grep -v '^$' | sort -u || true)
    else
      readable_cache[$base]=0
      required_cache[$base]=""
    fi
  fi

  if [ "${readable_cache[$base]}" != "1" ]; then
    echo "could not READ ${base} rulesets — cannot determine required contexts, skipping PR #$n (token/API blip must not be reported as a jam)"
    echo "::endgroup::"
    continue
  fi
  required="${required_cache[$base]}"
  if [ -z "$required" ]; then
    echo "no required contexts on ${base} — nothing to check for PR #$n"
    echo "::endgroup::"
    continue
  fi

  if ! commit=$(gh api "repos/${GH_REPO}/commits/${sha}" 2>/dev/null); then
    echo "could not READ commit ${sha} — skipping PR #$n"
    echo "::endgroup::"
    continue
  fi
  committed_at=$(printf '%s' "$commit" | jq -r '.commit.committer.date // .commit.author.date // empty' 2>/dev/null || true)
  committed_epoch=$(date -u -d "${committed_at:-}" +%s 2>/dev/null || echo 0)
  now=$(date -u +%s)
  age=$(( now - committed_epoch ))
  if [ "$committed_epoch" -le 0 ] || [ "$age" -lt "$grace_sec" ]; then
    echo "head ${sha} is only ${age}s old (grace=${grace_sec}s) — CI may still be settling, skipping PR #$n this run (a fresh PR must never report as jammed)"
    echo "::endgroup::"
    continue
  fi

  if ! runs=$(gh api "repos/${GH_REPO}/commits/${sha}/check-runs" --paginate 2>/dev/null); then
    echo "could not READ check-runs for ${sha} — skipping PR #$n"
    echo "::endgroup::"
    continue
  fi
  pending=$(printf '%s' "$runs" | jq -r '[.check_runs[]? | select(.status != "completed") | .name] | .[]' 2>/dev/null || true)
  if [ -n "$pending" ]; then
    echo "checks still in flight on ${sha} for PR #$n ($(printf '%s' "$pending" | tr '\n' ',')) — not settled yet, skipping this run"
    echo "::endgroup::"
    continue
  fi
  reported=$(printf '%s' "$runs" | jq -r '[.check_runs[]?.name] | .[]' 2>/dev/null | sed 's/^ *//' | grep -v '^$' | sort -u || true)
  if statuses=$(gh api "repos/${GH_REPO}/commits/${sha}/status" 2>/dev/null); then
    status_contexts=$(printf '%s' "$statuses" | jq -r '[.statuses[]?.context] | .[]' 2>/dev/null || true)
    reported=$(printf '%s\n%s' "$reported" "$status_contexts" | sed 's/^ *//' | grep -v '^$' | sort -u || true)
  fi

  never_reporting=""
  while IFS= read -r gate; do
    [ -z "$gate" ] && continue
    if ! context_reachable "$gate" "$reported"; then
      never_reporting="${never_reporting:+$never_reporting$'\n'}$gate"
    fi
  done <<< "$required"

  if [ -z "$never_reporting" ]; then
    echo "all required contexts on ${base} reported on ${sha} — PR #$n reachable"
    echo "::endgroup::"
    continue
  fi

  found_any=1
  # Only (re-)fetch while we haven't already gotten a real answer this run — but unlike
  # caching `{}` as ground truth, a failed fetch does NOT get cached: it retries on the
  # next PR that needs it (a transient blip on PR #1 must not silently disable
  # disabled-workflow detection for every other PR flagged this run, #518) and this PR's
  # own classification falls back to "unknown" rather than assuming zero disabled workflows.
  if [ -z "${workflows_json}" ] && [ "$workflows_fetch_failed" -ne 1 ]; then
    if workflows_json=$(gh api "repos/${GH_REPO}/actions/workflows" --paginate 2>/dev/null); then
      :
    else
      workflows_json=""
      workflows_fetch_failed=1
    fi
  fi
  pr_has_disabled=0
  pr_has_generic=0
  if [ "$workflows_fetch_failed" -eq 1 ]; then
    echo "::warning::could not READ workflow list for ${GH_REPO} — cannot determine whether PR #$n's never-reporting context(s) are caused by a disabled workflow, skipping disabled-workflow classification for this PR (API blip must not be reported as zero disabled workflows)"
  else
    while IFS= read -r gate; do
      [ -z "$gate" ] && continue
      disabled_wf=$(printf '%s' "$workflows_json" | jq -r --arg g "$gate" \
        '[.workflows[]? | select(.state == "disabled_manually") | .name as $n | select($n == $g or ($g | startswith($n + " / ")))] | .[0].name // empty' 2>/dev/null || true)
      if [ -n "$disabled_wf" ]; then
        pr_has_disabled=1
        echo "::warning::required context '${gate}' can never report on PR #$n — its workflow ('${disabled_wf}') is manually disabled. Remedy: re-enable the workflow."
      else
        pr_has_generic=1
        echo "::warning::required context '${gate}' has not reported on PR #$n head ${sha} after ${grace_minutes}m. Remedy: if it's a path-filtered required workflow that doesn't match this PR's diff, drop it from required or add a no-op reporting job; if this PR predates the context (onboarding window), push an empty commit to re-fire 'synchronize' (close/reopen does NOT work)."
      fi
    done <<< "$never_reporting"
  fi
  # Only queue for the empty-commit retry when EVERY never-reporting gate on this PR is
  # the generic cause — a PR with a disabled-workflow gate mixed in needs the operator
  # to re-enable that workflow, and an empty commit wouldn't fix it anyway. A PR whose
  # disabled-workflow status is unknown (fetch failed) is excluded here too, not just
  # from the disabled branch, since we can't confirm it's purely generic.
  if [ "$workflows_fetch_failed" -ne 1 ] && [ "$pr_has_generic" -eq 1 ] && [ "$pr_has_disabled" -eq 0 ]; then
    generic_prs+=("$n")
  fi
  n_missing=$(printf '%s\n' "$never_reporting" | grep -c .)
  echo "::error::PR #$n: ${n_missing} required context(s) on ${base} cannot report on head ${sha} — see warnings above for cause + remedy. This PR is likely PERMANENTLY BLOCKED with no failing check to fix."
  echo "::endgroup::"
done

# Machine-readable handoff for pr-unstick.yml's reachability-retry sweep (#379): the PR
# numbers here are safe to retry with an empty commit (harmless no-op if the real cause
# turns out to be a path filter — the PR just stays flagged for a human either way).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  joined=$(IFS=,; echo "${generic_prs[*]:-}")
  echo "generic-unreachable-prs=${joined}" >> "$GITHUB_OUTPUT"
fi

if [ "$found_any" -eq 1 ]; then
  exit 1
fi
echo "no unreachable required contexts found on any open PR"
