#!/usr/bin/env bash
#
# Regression test: issue-build's SCHEDULED-sweep selection must never claim a gated
# (`needs-human` / `hold`) issue.
#
# A gated issue that gets re-selected every sweep is re-claimed → attempted → dropped,
# burning turns/credit on work a human deliberately fenced off — the dominant credit leak
# a pipeline-cost audit flagged. This exclusion HAS existed since #169 and is centralized in
# the nonbuildable-labels composite action (#317/#318), applied by BOTH the `select` (claim)
# and `requeue` (dispatch-count) jobs. This test locks that invariant so it can't silently
# regress — the label floor is one small string edit away from dropping a label, and the
# select filter is one `.some()` away from not applying it.
#
# It (A) asserts the single-source-of-truth floor still carries both gate labels, (B) drives
# the ACTUAL select-job buildable filter extracted from the workflow (no hand-copied stand-in —
# same principle as test-issue-build-prereq-gating.sh) over fixtures, and (C) structurally
# confirms both claim paths honor the shared floor.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
wf="$here/.github/workflows/issue-build.yml"
action="$here/.github/actions/nonbuildable-labels/action.yml"

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v node >/dev/null || { echo "FAIL: node not on PATH" >&2; exit 1; }

fail=0

# ── (A) Single source of truth: the nonbuildable-labels floor still carries both gates ───────
floor="$(grep -oE 'labels=[A-Za-z,-]+' "$action" | head -1 | cut -d= -f2)"
[ -n "$floor" ] || { echo "FAIL: could not read the label floor from $action" >&2; exit 1; }
echo "nonbuildable-labels floor: $floor"
for want in needs-human hold; do
  case ",$floor," in
    *,"$want",*) echo "ok   - floor includes '$want'" ;;
    *) echo "FAIL - floor is MISSING '$want' — gated issues would become selectable" >&2; fail=1 ;;
  esac
done

# ── (B) Drive the REAL select-job buildable filter over fixtures ──────────────────────────────
script="$(yq -r '.jobs.select.steps[] | select(.id == "pick") | .with.script' "$wf")"
block="$(printf '%s\n' "$script" | awk '/const buildableRaw = all.filter/{f=1} /const buildable = buildableRaw.map/{f=0} f')"
if ! printf '%s' "$block" | grep -q 'nonBuildableLabels.some'; then
  echo "FAIL: could not extract the buildable filter (its nonBuildableLabels.some guard) from the select step — anchors moved?" >&2
  exit 1
fi

FLOOR="$floor" BLOCK="$block" node <<'NODE'
const floor = process.env.FLOOR.split(",");
const block = process.env.BLOCK;

// The real select step runs this filter after computing nonBuildableLabels (from the composite
// action, injected here as the REAL floor), referencedByOpenPr, isTrusted, include, exclude. We
// inject those exactly as the step defines them so ONLY the label-gate behavior is under test:
// trust is granted (isolate the label filter), nothing is PR-referenced, no include/exclude.
const runFilter = (all) => {
  const nonBuildableLabels = floor;
  const referencedByOpenPr = new Set();
  const isTrusted = () => true;
  const include = [];
  const exclude = [];
  const fn = new Function(
    "all", "nonBuildableLabels", "referencedByOpenPr", "isTrusted", "include", "exclude",
    block + "\nreturn buildableRaw.map((i) => i.number);",
  );
  return fn(all, nonBuildableLabels, referencedByOpenPr, isTrusted, include, exclude);
};

const issue = (number, labels = []) => ({ number, user: { id: 1 }, author_association: "OWNER", labels: labels.map((name) => ({ name })) });

const all = [
  issue(1, ["effort:small"]),               // plain buildable
  issue(2, ["needs-human"]),                // gated → excluded
  issue(3, ["hold"]),                       // gated → excluded
  issue(4, ["effort:large", "needs-human"]),// gated even with a normal label alongside
  issue(5, ["tracking"]),                   // bookkeeping → excluded
  issue(6, ["epic"]),                       // epic → excluded
  issue(7, ["building"]),                   // in-flight claim → excluded
  issue(8, []),                             // unlabeled → buildable (default medium)
  { number: 9, pull_request: {}, user: { id: 1 }, author_association: "OWNER", labels: [{ name: "needs-human" }] }, // a PR, not an issue
];

const got = runFilter(all).sort((a, b) => a - b);
const want = [1, 8];
let failures = 0;
const eq = JSON.stringify(got) === JSON.stringify(want);
if (eq) {
  console.log(`ok   - buildable = ${JSON.stringify(got)} (gated/needs-human/hold/tracking/epic/building/PR all excluded)`);
} else {
  console.log(`FAIL - buildable: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`);
  failures++;
}
// Point assertions the task calls out explicitly: a needs-human/hold issue is NOT selected
// while a normal one IS.
for (const n of [2, 3, 4]) {
  if (!got.includes(n)) console.log(`ok   - gated issue #${n} not selected`);
  else { console.log(`FAIL - gated issue #${n} WAS selected`); failures++; }
}
if (got.includes(1)) console.log("ok   - normal issue #1 selected");
else { console.log("FAIL - normal issue #1 was NOT selected"); failures++; }

if (failures) process.exit(1);
NODE
# shellcheck disable=SC2181
[ $? -eq 0 ] || fail=1

# ── (C) Both claim paths (select + requeue) honor the shared floor ────────────────────────────
paths="$(grep -c 'nonBuildableLabels.some((l) => labels.includes(l))' "$wf" || true)"
if [ "${paths:-0}" -ge 2 ]; then
  echo "ok   - both select and requeue apply the nonBuildableLabels floor ($paths call sites)"
else
  echo "FAIL - expected the nonBuildableLabels floor to be applied in BOTH select and requeue (found $paths call site(s))" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "All pre-flight exclusion assertions passed."
else
  echo "Pre-flight exclusion assertions FAILED." >&2
fi
exit "$fail"
