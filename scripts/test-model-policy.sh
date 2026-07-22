#!/usr/bin/env bash
# Unit-tests .github/model-policy.json (#369) against the live config it's meant to
# single-source: fixer.yml/issue-build.yml's reusable model defaults, the self-*.yml and
# scaffold-caller.sh-emitted caller-stub pins, issue-build's sensedOpus opt-in-only
# escalation, and budget-governor.yml's OPUS_WF_RE classification. All five have to agree
# by hand today, which is exactly why they drifted once already: fixer.yml's `model`
# default flipped opus->sonnet in #373 (reconciling the 2026-07-17 "sonnet pinned
# org-wide, no Opus escalation" operator directive), but budget-governor.yml's
# OPUS_WF_RE — and scripts/test-budget-governor-opus-classify.sh — still expected the
# bare "Self fixer"/"Fixer" name to classify as opus for two days until this issue
# caught it. This gate turns that reconciliation into an invariant instead of a
# periodic manual pass: change any one of the five places without updating
# model-policy.json to match, and this fails.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

POLICY=.github/model-policy.json
SCAFFOLD=scripts/scaffold-caller.sh
BUDGET_GOVERNOR=.github/workflows/budget-governor.yml

[ -f "$POLICY" ] || { echo "test-model-policy: cannot find $POLICY" >&2; exit 2; }
jq empty "$POLICY" || { echo "test-model-policy: $POLICY is not valid JSON" >&2; exit 2; }

echo "[1/6] reusable workflow model-input defaults match policy"
while IFS= read -r row; do
  wf=$(jq -r '.workflow' <<<"$row")
  input=$(jq -r '.input' <<<"$row")
  expect=$(jq -r '.default' <<<"$row")
  got=$(yq -r ".on.workflow_call.inputs.\"$input\".default" "$wf")
  if [ "$got" = "$expect" ]; then
    note "$wf input '$input' default -> $got"
  else
    bad "$wf input '$input' default: expected '$expect', got '$got'"
  fi
done < <(jq -c '.reusable_model_defaults[]' "$POLICY")

echo "[2/6] checked-in self-*.yml caller-stub pins match policy"
while IFS= read -r row; do
  glob=$(jq -r '.glob' <<<"$row")
  input=$(jq -r '.job_input' <<<"$row")
  expect=$(jq -r '.value' <<<"$row")
  matched=0
  for f in $glob; do
    [ -e "$f" ] || continue
    matched=1
    got=$(yq -r ".jobs.*.with.\"$input\"" "$f")
    if [ "$got" = "$expect" ]; then
      note "$f with.'$input' -> $got"
    else
      bad "$f with.'$input': expected '$expect', got '$got' (unpinned or drifted)"
    fi
  done
  [ "$matched" -eq 1 ] || bad "no file matched glob '$glob'"
done < <(jq -c '.pinned_caller_stubs[]' "$POLICY")

echo "[3/6] scaffold-caller.sh emits the same pins for new callers"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash "$SCAFFOLD" -o "$tmp" -w "" >/dev/null
while IFS= read -r row; do
  emit=$(jq -r '.emit' <<<"$row")
  input=$(jq -r '.job_input' <<<"$row")
  expect=$(jq -r '.value' <<<"$row")
  f="$tmp/$emit.yml"
  if [ ! -f "$f" ]; then
    bad "scaffold-caller.sh never emitted '$emit.yml'"
    continue
  fi
  got=$(yq -r ".jobs.*.with.\"$input\"" "$f")
  if [ "$got" = "$expect" ]; then
    note "emit $emit with.'$input' -> $got"
  else
    bad "emit $emit with.'$input': expected '$expect', got '$got'"
  fi
done < <(jq -c '.scaffolded_caller_stubs[]' "$POLICY")

echo "[4/6] issue-build's sensedOpus escalation stays opt-in — no current caller sets it"
esc_input=$(jq -r '.escalation_opt_in_only.input' "$POLICY")
esc_value=$(jq -r '.escalation_opt_in_only.escalation_value' "$POLICY")
esc_default=$(yq -r ".on.workflow_call.inputs.\"$esc_input\".default" "$(jq -r '.escalation_opt_in_only.workflow' "$POLICY")")
if [ "$esc_default" = "$esc_value" ]; then
  bad "issue-build.yml's '$esc_input' default is '$esc_value' — sensedOpus escalation is reachable by default, contradicting the no-escalation policy"
else
  note "issue-build.yml '$esc_input' default ('$esc_default') != escalation value ('$esc_value')"
fi
for f in .github/workflows/self-issue-build.yml "$tmp/issue-build.yml"; do
  [ -f "$f" ] || continue
  got=$(yq -r ".jobs.*.with.\"$esc_input\" // \"\"" "$f")
  if [ "$got" = "$esc_value" ]; then
    bad "$f pins '$esc_input: $esc_value' — sensedOpus escalation is reachable, contradicting the no-escalation policy"
  else
    note "$f '$esc_input' -> '${got:-<unset, inherits sonnet default>}' (not opted into escalation)"
  fi
done

echo "[5/6] budget-governor.yml's OPUS_WF_RE agrees with the policy's tier assignment"
opus_re=$(yq -r ".env.$(jq -r '.budget_governor.opus_regex_env' "$POLICY")" "$BUDGET_GOVERNOR")
classify() { jq -n --arg n "$1" --arg re "$opus_re" 'if ($n | test($re; "i")) then "opus" else "sonnet" end' | tr -d '"'; }
while IFS= read -r n; do
  got=$(classify "$n")
  if [ "$got" = "opus" ]; then note "'$n' -> opus (policy-declared opus tier)"; else bad "'$n': policy declares opus tier, OPUS_WF_RE classifies '$got'"; fi
done < <(jq -r '.opus_tier_workflow_names[]' "$POLICY")
while IFS= read -r n; do
  got=$(classify "$n")
  if [ "$got" = "sonnet" ]; then note "'$n' -> sonnet (policy-declared sonnet tier)"; else bad "'$n': policy declares sonnet tier, OPUS_WF_RE classifies '$got'"; fi
done < <(jq -r '.sonnet_tier_workflow_names[]' "$POLICY")

echo "[6/6] effort-gating: effort:large is in the shared nonbuildable-labels floor (2026-07-21 setpoint)"
# The setpoint gates effort:large to human review by adding it to the shared floor. Assert the
# policy's declared gate label is actually excluded by the action's emitted floor, so the two
# can't drift (the exact #310/#318 antipattern the floor exists to prevent).
eg_label=$(jq -r '.effort_gating.gated_label' "$POLICY")
eg_action=$(jq -r '.effort_gating.nonbuildable_action' "$POLICY")
floor=$(grep -oE 'labels=[A-Za-z,:-]+' "$eg_action" | head -1 | cut -d= -f2)
if [ -z "$floor" ]; then
  bad "could not read the nonbuildable-labels floor from '$eg_action'"
elif printf ',%s,' "$floor" | grep -qF ",$eg_label,"; then
  note "effort-gate '$eg_label' present in the floor ($floor)"
else
  bad "policy gates '$eg_label' but the nonbuildable-labels floor ($floor) does not exclude it — large work would be auto-built"
fi
# The opus-on-fail turn-cap retry is RATIFIED but implementation is PENDING (F2b). Assert it stays
# declared-pending (not silently claimed active) so docs/policy don't outrun the code. When F2b
# lands the retry step in issue-build.yml, flip status to "active" here and add the code assertion.
tr_status=$(jq -r '.turncap_retry.status' "$POLICY")
case "$tr_status" in
  pending) note "turncap_retry status='pending' (F2b not yet implemented — correctly not asserted against code)" ;;
  active)  bad "turncap_retry.status='active' but this test has no code assertion for it — add the issue-build.yml retry-step check before flipping to active" ;;
  *)       bad "turncap_retry.status must be 'pending' (or 'active' once F2b + its code assertion land), got '$tr_status'" ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "All model-policy assertions passed."
else
  echo "model-policy assertions FAILED." >&2
fi
exit "$fail"
