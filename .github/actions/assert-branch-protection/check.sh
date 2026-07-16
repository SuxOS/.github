#!/usr/bin/env bash
# Decision logic for the "Assert base branch protection requires the security
# gates" step. Kept in its own file (rather than inline in action.yml) so
# scripts/test-assert-branch-protection.sh can exercise it directly against a
# mocked `gh`, with no network — see that script for the fail-open/fail-closed
# fixtures this logic must satisfy.
set -uo pipefail

required=""
rules_ok=false
if prot=$(gh api "repos/${GITHUB_REPOSITORY}/branches/${BASE_BRANCH}/protection" 2>/dev/null); then
  prot_gates="$(printf '%s' "$prot" | jq -r '[(.required_status_checks.contexts // [])[], (.required_status_checks.checks // [])[].context] | .[]' 2>/dev/null || true)"
  required="$(printf '%s\n%s' "$required" "$prot_gates")"
fi
if rules=$(gh api "repos/${GITHUB_REPOSITORY}/rules/branches/${BASE_BRANCH}" 2>/dev/null); then
  rules_ok=true
  rule_gates="$(printf '%s' "$rules" | jq -r '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | .[]' 2>/dev/null || true)"
  required="$(printf '%s\n%s' "$required" "$rule_gates")"
fi
read_ok="$rules_ok"
if [ "$read_ok" != "true" ]; then
  echo "::warning::could not READ ${BASE_BRANCH} branch protection OR rulesets (token perms / network) — cannot determine protection state, so continuing WITHOUT blocking; a token/API blip must not jam the queue. If the checks are required, GitHub still gates the actual merge."
else
  # grep -v exits 1 when required ends up empty (no gates found on either
  # surface) — under pipefail + the runner's bash -e, that silently killed
  # the whole script with no message. || true: empty is a valid state here,
  # handled below by the normal missing-gates comparison.
  required=$(printf '%s\n' "$required" | sed 's/^ *//' | grep -v '^$' | sort -u || true)
  missing=""
  while IFS= read -r gate; do
    [ -z "$gate" ] && continue
    # Segment-boundary match, NOT arbitrary substring. REQUIRED_GATES (the
    # caller's input default) and the live ruleset/branch-protection context
    # names are two independently-edited lists — a required-checks job-name
    # prefix (e.g. CI grouping a job as "audit / npm audit & SBOM") drifts them
    # apart even though the gate is still genuinely required. Bit us live:
    # fixing a ruleset context name to match reality broke a naive exact-match
    # check against the still-bare REQUIRED_GATES default. So we must tolerate
    # that prefix drift — but a plain `grep -qF "$gate"` substring test was too
    # loose (issue #210): a live required check named `security-review-experimental`
    # or `pre-security-review` would satisfy the `security-review` gate, silently
    # defeating the fail-closed guarantee this action exists to provide.
    #
    # GitHub joins check-name segments with " / " (workflow / job / step), and
    # the only observed drift is a *prefix* being prepended. So a gate matches a
    # live context iff the context equals the gate outright, or the gate is a
    # complete " / "-delimited trailing segment of it. That keeps the documented
    # prefix-drift tolerance while rejecting a merely superset-named check.
    matched=false
    while IFS= read -r ctx; do
      [ -z "$ctx" ] && continue
      if [ "$ctx" = "$gate" ] || [ "${ctx%" / $gate"}" != "$ctx" ]; then
        matched=true
        break
      fi
    done <<< "$required"
    if [ "$matched" != true ]; then
      missing="${missing:+$missing, }$gate"
    fi
  done <<< "$REQUIRED_GATES"
  if [ -n "$missing" ]; then
    echo "::error::${BASE_BRANCH} does NOT require these gates (checked classic protection + rulesets): $missing — refusing to enable auto-merge (they'd stay advisory and lose the race to fast CI). Add them to ${BASE_BRANCH}'s required_status_checks (branch protection or a ruleset) to re-arm auto-merge."
    exit 1
  fi
  echo "branch protection/ruleset OK: ${BASE_BRANCH} requires all security gates"
fi
