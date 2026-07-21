#!/usr/bin/env bash
#
# Regression test: issue-build's SCHEDULED-sweep selection must never claim a GATED issue —
# human-hold gates (`needs-human` / `hold`) and, since the 2026-07-21 setpoint, the
# human-approval gate `effort:large` (minor/easy features ungated, everything else needs a
# human go-ahead).
#
# A gated issue that gets re-selected every sweep is re-claimed → attempted → dropped, burning
# turns/credit on work a human deliberately fenced off. The needs-human/hold exclusion HAS
# existed since #169; `effort:large` was added to the same floor by the 2026-07-21 setpoint
# because a large issue just exhausts the Sonnet turn cap and lands needs-human anyway, so
# gating it open is cheaper than escalating. All are centralized in the nonbuildable-labels
# composite action (#317/#318), applied by BOTH the `select` (claim) and `requeue`
# (dispatch-count) jobs. This test locks the invariant so it can't silently regress — the
# floor is one string edit from dropping a label, and the select filter one `.some()` from
# not applying it.
#
# It (A) asserts the single-source-of-truth floor still carries every gate label, (B) drives
# the ACTUAL select-job buildable filter extracted from the workflow (no hand-copied stand-in —
# same principle as test-issue-build-prereq-gating.sh) over fixtures — asserting a gated
# (needs-human/hold/effort:large) issue is NOT selected while a small/medium one IS — and
# (C) structurally confirms both claim paths honor the shared floor.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
wf="$here/.github/workflows/issue-build.yml"
action="$here/.github/actions/nonbuildable-labels/action.yml"

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v node >/dev/null || { echo "FAIL: node not on PATH" >&2; exit 1; }

fail=0

# ── (A) Single source of truth: the nonbuildable-labels floor still carries both gates ───────
floor="$(grep -oE 'labels=[A-Za-z,:-]+' "$action" | head -1 | cut -d= -f2)"
[ -n "$floor" ] || { echo "FAIL: could not read the label floor from $action" >&2; exit 1; }
echo "nonbuildable-labels floor: $floor"
for want in needs-human hold effort:large; do
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
  issue(1, ["effort:small"]),                // small → buildable
  issue(2, ["needs-human"]),                 // human-hold gate → excluded
  issue(3, ["hold"]),                        // human-hold gate → excluded
  issue(4, ["effort:large", "needs-human"]), // gated even with a normal label alongside
  issue(5, ["tracking"]),                    // bookkeeping → excluded
  issue(6, ["epic"]),                        // epic → excluded
  issue(7, ["building"]),                    // in-flight claim → excluded
  issue(8, []),                              // unlabeled → buildable (default medium)
  { number: 9, pull_request: {}, user: { id: 1 }, author_association: "OWNER", labels: [{ name: "needs-human" }] }, // a PR, not an issue
  issue(10, ["effort:large", "bug"]),        // 2026-07-21 setpoint: large is GATED for ALL types
                                             // incl. bugs (a large bug still needs human intent) → excluded
  issue(11, ["effort:medium", "bug"]),       // a medium bug → still auto-built (minor/easy ungated)
];

const got = runFilter(all).sort((a, b) => a - b);
const want = [1, 8, 11];
let failures = 0;
const eq = JSON.stringify(got) === JSON.stringify(want);
if (eq) {
  console.log(`ok   - buildable = ${JSON.stringify(got)} (needs-human/hold/effort:large/tracking/epic/building/PR all excluded; small/medium included)`);
} else {
  console.log(`FAIL - buildable: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`);
  failures++;
}
// Point assertions the task calls out explicitly: a gated issue (needs-human/hold, and a LONE
// effort:large per the 2026-07-21 setpoint) is NOT selected, while small/medium ARE.
for (const n of [2, 3, 4, 10]) {
  if (!got.includes(n)) console.log(`ok   - gated issue #${n} not selected`);
  else { console.log(`FAIL - gated issue #${n} WAS selected`); failures++; }
}
for (const [n, kind] of [[1, "small"], [11, "medium bug"]]) {
  if (got.includes(n)) console.log(`ok   - ${kind} issue #${n} selected (ungated auto-lane)`);
  else { console.log(`FAIL - ${kind} issue #${n} was NOT selected`); failures++; }
}

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
