#!/usr/bin/env bash
#
# Unit-tests issue-build.yml's `requeue` job concurrency cap (SuxOS/.github#434).
#
# `parallel-batches` is documented (and its own PR history: 4 -> 2, "don't run too hot")
# as bounding how many builder PRs race the same base at once. But the fan-out step only
# ever counted in_progress/queued WORKFLOW RUNS toward that cap — once a batch's `build`
# job finishes and opens a PR, the run drops out of "in_progress" while the PR it opened
# stays open (often for hours, waiting on CI/automerge), so `inFlight` silently forgot
# about it. requeue then kept dispatching fresh batches past the intended cap, letting
# concurrently-open bot/issue-build-* PRs pile up well beyond `parallel-batches` — the
# mutual-conflict generator behind #434's 7-PR DIRTY pileup (all touching shared hot files
# like test_hooks.sh/block-egress.py). The fix takes inFlight as
# max(in-progress-or-queued runs, currently-open builder PRs) instead of runs alone.
#
# This extracts the ACTUAL fan-out script shipped in the workflow (no hand-copied
# stand-in — same principle as test-issue-build-prereq-gating.sh) and drives it with
# fixture runs/PRs/issues, asserting the cap is honoured even when every batch that
# contributed to it has already finished its run and left an open PR behind.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
wf="$here/.github/workflows/issue-build.yml"

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v node >/dev/null || { echo "FAIL: node not on PATH" >&2; exit 1; }

script="$(yq -r '.jobs.requeue.steps[] | select(.name == "Fan out up to parallel-batches while unclaimed backlog remains") | .with.script' "$wf")"

if ! printf '%s' "$script" | grep -q 'const openBuilderPrs'; then
  echo "FAIL: could not extract requeue fan-out script (anchors moved?)" >&2
  exit 1
fi

# Mirrors the real workflow's "Checkout SuxOS/.github (shared trust predicate)" step
# (#551), which lands scripts/lib/is-trusted-author.js at $GITHUB_WORKSPACE/.suxos-ci —
# the extracted script's require() needs it at that same relative location here.
tmpws=$(mktemp -d)
trap 'rm -rf "$tmpws"' EXIT
mkdir -p "$tmpws/.suxos-ci/scripts/lib"
cp "$here/scripts/lib/is-trusted-author.js" "$tmpws/.suxos-ci/scripts/lib/"
export GITHUB_WORKSPACE="$tmpws"

SCRIPT="$script" node <<'NODE'
const scriptBody = process.env.SCRIPT;

const trusted = { login: "suxbot[bot]", id: 1 };
const issue = (number, labels = []) => ({
  number, pull_request: undefined, labels: labels.map((name) => ({ name })),
  user: trusted, author_association: "OWNER",
});
const pr = (number, ref, body = "") => ({
  number, body, user: trusted, author_association: "OWNER", head: { ref },
});
const wfRun = (name) => ({ name });

const issuesListForRepo = Symbol("issues.listForRepo");
const pullsList = Symbol("pulls.list");

// Runs the real extracted script with fixture GitHub state; returns how many new batches
// it dispatched plus the `inFlight=` summary line for direct assertions on the cap math.
const run = async ({
  issues = [], prs = [], inProgressRuns = [], queuedRuns = [], cap = 2, maxIssues = 3,
  useRecommended, spineAvailable, spineRecommended, throttleLevel,
}) => {
  const dispatched = [];
  const infoLines = [];
  const core = { info: (m) => infoLines.push(m), warning: () => {} };
  const github = {
    paginate: async (fn) => {
      if (fn === issuesListForRepo) return issues;
      if (fn === pullsList) return prs;
      throw new Error("unexpected paginate target");
    },
    rest: {
      issues: { listForRepo: issuesListForRepo },
      pulls: { list: pullsList },
      actions: {
        listWorkflowRunsForRepo: async ({ status }) => ({
          data: { workflow_runs: status === "in_progress" ? inProgressRuns : queuedRuns },
        }),
        createWorkflowDispatch: async (o) => { dispatched.push(o); },
      },
    },
  };
  const context = { repo: { owner: "SuxOS", repo: "test-repo" } };
  process.env.WORKFLOW_REF = "SuxOS/test-repo/.github/workflows/issue-build.yml@refs/heads/main";
  process.env.REF_NAME = "main";
  process.env.MAX_ISSUES = String(maxIssues);
  process.env.PARALLEL_BATCHES = String(cap);
  process.env.NONBUILDABLE_LABELS = "tracking,epic";
  process.env.INCLUDE = "";
  process.env.EXCLUDE = "";
  // Drain-controller inputs (#476) — undefined (matches an unset env var) unless a test
  // passes them explicitly, so every existing case above still runs with the recommendation
  // path fully inert (spineAvailable !== "true" -> effectiveCap === cap, unchanged behaviour).
  if (useRecommended !== undefined) process.env.USE_RECOMMENDED = String(useRecommended); else delete process.env.USE_RECOMMENDED;
  if (spineAvailable !== undefined) process.env.SPINE_AVAILABLE = String(spineAvailable); else delete process.env.SPINE_AVAILABLE;
  if (spineRecommended !== undefined) process.env.SPINE_RECOMMENDED_PARALLEL_BATCHES = String(spineRecommended); else delete process.env.SPINE_RECOMMENDED_PARALLEL_BATCHES;
  if (throttleLevel !== undefined) process.env.THROTTLE_LEVEL = String(throttleLevel); else delete process.env.THROTTLE_LEVEL;

  const fn = new Function("github", "context", "core", `return (async () => { ${scriptBody} })();`);
  await fn(github, context, core);
  const summary = infoLines.find((l) => l.startsWith("unclaimed=")) || "";
  const drainLine = infoLines.find((l) => l.startsWith("drain-controller:")) || "";
  return { dispatchedCount: dispatched.length, summary, drainLine };
};

let failures = 0;
const check = async (name, opts, expectDispatched) => {
  const { dispatchedCount, summary } = await run(opts);
  if (dispatchedCount === expectDispatched) { console.log(`ok   - ${name} (${summary})`); return; }
  failures++;
  console.log(`FAIL - ${name}: got dispatched=${dispatchedCount} want ${expectDispatched} (${summary})`);
};

const backlog5 = [1, 2, 3, 4, 5].map((n) => issue(n));
const backlog10 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((n) => issue(n));

const checkDrain = async (name, opts, expectDispatched, expectDrainSubstring) => {
  const { dispatchedCount, summary, drainLine } = await run(opts);
  const dispatchOk = dispatchedCount === expectDispatched;
  const drainOk = expectDrainSubstring === null ? drainLine === "" : drainLine.includes(expectDrainSubstring);
  if (dispatchOk && drainOk) { console.log(`ok   - ${name} (${summary}) [${drainLine}]`); return; }
  failures++;
  console.log(`FAIL - ${name}: got dispatched=${dispatchedCount} want ${expectDispatched}, drainLine="${drainLine}" want ${expectDrainSubstring === null ? "(none)" : `to include "${expectDrainSubstring}"`} (${summary})`);
};

(async () => {
  // 1. The #434 bug case: no runs in_progress/queued (both prior batches already finished
  //    and merged into open PRs), but 2 builder PRs are already open — cap=2 must read as
  //    saturated even though inFlightRuns alone would read 0.
  await check(
    "both prior batches finished but left 2 open builder PRs -> cap already saturated",
    { issues: backlog5, prs: [pr(101, "bot/issue-build-abc"), pr(102, "bot/issue-build-def")], cap: 2 },
    0,
  );

  // 2. Common case unaffected: no open builder PRs yet, one run genuinely in progress ->
  //    still tops up to the cap exactly as before (max() must not under-dispatch either).
  await check(
    "no open builder PRs, 1 run in_progress -> tops up remaining headroom",
    { issues: backlog5, inProgressRuns: [wfRun("issue-build.yml")], cap: 2 },
    1,
  );

  // 3. In-progress runs alone can also saturate the cap before any PR opens.
  await check(
    "2 runs in_progress, 0 open builder PRs -> cap already saturated",
    { issues: backlog5, inProgressRuns: [wfRun("issue-build.yml"), wfRun("issue-build.yml")], cap: 2 },
    0,
  );

  // 4. A human/non-builder PR must not count toward the builder-PR concurrency estimate.
  await check(
    "open PR on a non-builder branch is not counted -> full headroom available",
    { issues: backlog5, prs: [pr(103, "feature/unrelated-human-work")], cap: 2 },
    2,
  );

  // 5. No unclaimed backlog -> no dispatch regardless of runs/PRs (early-return path intact).
  await check(
    "no unclaimed backlog -> no dispatch even with headroom",
    { issues: [], prs: [], cap: 2 },
    0,
  );

  // 6-10: drain-controller recommended_parallel_batches consumption (#476). backlog10 gives
  // wantForWork=4 (unclaimedPoints=20/effortBudget-default-6 -> ceil=4, unclaimed=10/maxIssues-
  // default-3 -> ceil=4), wide enough headroom that effectiveCap alone decides dispatch count.

  // 6. Spine signal unavailable -> recommendation ignored entirely (fail-soft), no log line,
  //    even though useRecommended is true and a recommendation value is present.
  await checkDrain(
    "spine unavailable -> recommendation ignored, static cap governs",
    { issues: backlog10, cap: 2, useRecommended: true, spineAvailable: false, spineRecommended: 4, throttleLevel: "green" },
    2, null,
  );

  // 7. Comparison-only (useRecommended false, the default): always logged, never applied —
  //    dispatch still bound by the static cap even though the recommendation (4) is higher.
  await checkDrain(
    "comparison-only (flag off) -> logged but static cap still governs dispatch",
    { issues: backlog10, cap: 2, useRecommended: false, spineAvailable: true, spineRecommended: 4, throttleLevel: "green" },
    2, "comparison-only, not applied",
  );

  // 8. Flag on, green headroom -> recommendation (4) raises the ceiling above the static
  //    default and dispatch actually reaches it.
  await checkDrain(
    "flag on, green headroom -> recommendation raises the ceiling",
    { issues: backlog10, cap: 2, useRecommended: true, spineAvailable: true, spineRecommended: 4, throttleLevel: "green" },
    4, "USING",
  );

  // 9. Flag on, yellow headroom -> raw 4 dampened by 0.5 to 2, which floors right back at the
  //    static default (max(2,2)=2) — dampening pulls it toward, not below, the static default.
  await checkDrain(
    "flag on, yellow headroom -> dampened recommendation lands back at the static default",
    { issues: backlog10, cap: 2, useRecommended: true, spineAvailable: true, spineRecommended: 4, throttleLevel: "yellow" },
    2, "dampened=2",
  );

  // 10. Flag on, a recommendation BELOW the static default must never lower the ceiling —
  //     max(static, dampened) floors at the operator-configured value.
  await checkDrain(
    "flag on, recommendation below static default -> never pushed below the floor",
    { issues: backlog10, cap: 2, useRecommended: true, spineAvailable: true, spineRecommended: 1, throttleLevel: "green" },
    2, "recommended ceiling=2",
  );

  // 11. Spine available but the recommendation field itself is empty (documented fail-soft
  //     contract: empty means "no data for this field", distinct from spine unavailability,
  //     #515) -> must be treated as unavailable, not coerced by Number('') === 0 into a
  //     bogus "recommend 0" that would otherwise still pass the >=0 check.
  await checkDrain(
    "spine available but recommendation field is empty -> treated as unavailable, not Number('')=0",
    { issues: backlog10, cap: 2, useRecommended: true, spineAvailable: true, spineRecommended: "", throttleLevel: "green" },
    2, null,
  );

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log("\nall requeue-cap assertions passed");
})();
NODE
