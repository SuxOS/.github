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
const run = async ({ issues = [], prs = [], inProgressRuns = [], queuedRuns = [], cap = 2, maxIssues = 3 }) => {
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

  const fn = new Function("github", "context", "core", `return (async () => { ${scriptBody} })();`);
  await fn(github, context, core);
  const summary = infoLines.find((l) => l.startsWith("unclaimed=")) || "";
  return { dispatchedCount: dispatched.length, summary };
};

let failures = 0;
const check = async (name, opts, expectDispatched) => {
  const { dispatchedCount, summary } = await run(opts);
  if (dispatchedCount === expectDispatched) { console.log(`ok   - ${name} (${summary})`); return; }
  failures++;
  console.log(`FAIL - ${name}: got dispatched=${dispatchedCount} want ${expectDispatched} (${summary})`);
};

const backlog5 = [1, 2, 3, 4, 5].map((n) => issue(n));

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

  if (failures) { console.error(`\n${failures} assertion(s) failed`); process.exit(1); }
  console.log("\nall requeue-cap assertions passed");
})();
NODE
