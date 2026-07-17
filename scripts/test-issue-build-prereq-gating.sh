#!/usr/bin/env bash
#
# Unit-tests issue-build.yml's prerequisite-gating heuristic (#348).
#
# The `select` step defers an open issue that names a STILL-OPEN issue as a hard
# prerequisite (e.g. #342/#343 "Extend the dashboard-query gate…" while #339 — which
# added that gate's script — sat on an unmerged PR), so the builder isn't handed work
# whose file doesn't exist on main yet. The gate is advisory and non-starving: it may
# only reorder, never empty the batch.
#
# This extracts the ACTUAL detection block shipped in the workflow (no hand-copied
# stand-in — same principle as test-scaffold-caller-regression.sh) and drives it with
# fixture issue sets, asserting which issues get deferred and that gating never starves.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
wf="$here/.github/workflows/issue-build.yml"

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v node >/dev/null || { echo "FAIL: node not on PATH" >&2; exit 1; }

# Pull the select step's github-script body, then slice out the self-contained
# prerequisite-gating block: from `const NON_CLOSEABLE` up to (but not including) the
# `// Effort points:` comment. It depends only on `all`, `buildableRaw`, `buildable`
# and `core`, which the harness below injects.
script="$(yq -r '.jobs.select.steps[] | select(.id == "pick") | .with.script' "$wf")"
block="$(printf '%s\n' "$script" | awk '/const NON_CLOSEABLE/{f=1} /\/\/ Effort points:/{f=0} f')"

if ! printf '%s' "$block" | grep -q 'const NON_CLOSEABLE'; then
  echo "FAIL: could not extract prerequisite-gating block from select step (anchors moved?)" >&2
  exit 1
fi

BLOCK="$block" node <<'NODE'
const block = process.env.BLOCK;

// Reconstruct the two inputs the real select step feeds the block: buildableRaw is the
// filtered full-issue objects (kept for title/body), buildable is the mapped {number,labels}.
// `buildableNumbers` (optional) restricts which open issues are buildable candidates — this
// models the real filters (trust, labels, referencedByOpenPr) that run before the block, so a
// blocker sitting on an open PR is still in `all`/blockerNumbers but not itself buildable.
const runGate = (all, buildableNumbers) => {
  const isCandidate = buildableNumbers ? (n) => buildableNumbers.includes(n) : () => true;
  const buildableRaw = all.filter((i) => !i.pull_request && isCandidate(i.number));
  const buildable = buildableRaw.map((i) => ({ number: i.number, labels: (i.labels || []).map((l) => l.name) }));
  const core = { info: () => {} };
  const fn = new Function("all", "buildableRaw", "buildable", "core", block + "\nreturn { selectable, deferred };");
  return fn(all, buildableRaw, buildable, core);
};

// Fixture helpers: an issue is {number, title, body, labels:[{name}]}; a PR carries pull_request.
const issue = (number, title, body, labels = []) => ({ number, title, body, labels: labels.map((name) => ({ name })) });

let failures = 0;
const nums = (arr) => arr.map((x) => x.number).sort((a, b) => a - b);
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const check = (name, all, expectDeferred, expectSelectable, buildableNumbers) => {
  const { selectable, deferred } = runGate(all, buildableNumbers);
  const gotDef = nums(deferred);
  const okDef = eq(gotDef, [...expectDeferred].sort((a, b) => a - b));
  const gotSel = nums(selectable);
  const okSel = expectSelectable === undefined ? true : eq(gotSel, [...expectSelectable].sort((a, b) => a - b));
  if (okDef && okSel) { console.log(`ok   - ${name}`); return; }
  failures++;
  console.log(`FAIL - ${name}`);
  if (!okDef) console.log(`        deferred: got ${JSON.stringify(gotDef)} want ${JSON.stringify(expectDeferred)}`);
  if (!okSel) console.log(`        selectable: got ${JSON.stringify(gotSel)} want ${JSON.stringify(expectSelectable)}`);
};

// 1. The motivating case: #342/#343 titled "Extend the dashboard-query gate…" reference
//    #339 (open, a normal issue) in their bodies → both deferred; the unrelated #350 is not.
const open339 = issue(339, "Add a dashboard-query invariant gate", "adds scripts/test-dashboard-queries.sh");
const i342 = issue(342, "Extend the dashboard-query gate to also assert README's metric table", "test-dashboard-queries.sh (#339) derives the surface; extend it.");
const i343 = issue(343, "Extend the dashboard-query gate to catch the #291 class", "The #339 gate covers existence but not the emit-only-when-disabled class.");
const i350 = issue(350, "fabric-health run-list loop multiplies API calls", "unrelated perf work, no dependency.");
check("motivating: title-extends + body #339 ref → defer #342/#343, not #350",
  [open339, i342, i343, i350], [342, 343], [339, 350]);

// 2. Non-starving: when the blocker (#339) is unmerged-but-not-buildable (on an open PR) and
//    the only buildable candidate (#342) is deferred, selectable falls back to the full set so
//    the pipeline still drains (pre-#348 behaviour) — a deferred issue is never dropped.
check("non-starving: sole buildable issue is deferred → still selectable",
  [open339, i342], [342], [342], [342]);

// 3. Blocker already merged/closed (not in the open set) → prerequisite satisfied, no defer.
check("closed blocker: #339 absent from open set → #342 not deferred",
  [i342], [], [342]);

// 4. Tracking/needs-human/hold issues are NOT blockers (they may never close → would starve).
const track243 = issue(243, "Autonomy throttle", "bookkeeping", ["tracking"]);
const dependsOnTracking = issue(401, "Add retry backoff", "depends on #243 landing first.");
check("tracking blocker excluded: 'depends on #243' (tracking) → not deferred",
  [track243, dependsOnTracking], [], [243, 401]);

// 5. Adjacency signal (no extension verb in title): "blocked by #402" with #402 open → deferred.
const open402 = issue(402, "Land the shared helper", "the helper other work needs");
const adj = issue(403, "Wire the new command", "Straightforward, but blocked by #402 (needs its helper).");
check("adjacency: 'blocked by #402' → deferred",
  [open402, adj], [403], [402]);

// 6. Self-reference must never defer an issue against itself.
const selfRef = issue(500, "Extend the widget", "This extends #500's own earlier note. see #500.");
check("self-reference: 'extends #500' in #500 → not deferred",
  [selfRef], [], [500]);

// 7. A bare cross-reference WITHOUT an extension verb in the title and without an adjacency
//    phrase is not a prerequisite (avoids over-deferring casually-linked issues).
const open404 = issue(404, "Some other work", "body");
const casual = issue(405, "Fix the typo in the banner", "Similar area to #404 but independent.");
check("casual cross-ref (no verb, no adjacency phrase) → not deferred",
  [open404, casual], [], [404, 405]);

// 8. (#370) An open PR cited by number as a prerequisite gates the child: PRs share the issue
//    number space and aren't in blockerNumbers, so a "depends on PR #341" child was never
//    deferred despite the regex/comment advertising exactly that phrasing. #341 (an open PR,
//    tagged pull_request) is excluded from buildableRaw but must still defer its dependent.
const pr341 = { number: 341, title: "feat: land the helper", body: "", pull_request: {}, labels: [] };
const childOnPr = issue(342, "Wire the new command", "depends on PR #341 landing first.");
check("(#370) open-PR prerequisite 'depends on PR #341' → deferred", [pr341, childOnPr], [342], [342]);

// 9. (#370 guard) A casual open-PR reference — no dependency verb, no title-extension — must
//    NOT defer, same tight-signal bar as issue refs; an unrelated open PR # in a body can't
//    over-defer.
const pr360 = { number: 360, title: "chore: cleanup", body: "", pull_request: {}, labels: [] };
const casualPr = issue(361, "Fix the banner typo", "Nearby #360 but independent of it.");
check("(#370 guard) casual open-PR ref (no verb) → not deferred", [pr360, casualPr], [], [361]);

if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
console.log("\nall prerequisite-gating assertions passed");
NODE
