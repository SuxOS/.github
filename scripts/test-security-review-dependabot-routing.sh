#!/usr/bin/env bash
#
# Unit-tests the Dependabot security-review routing (SuxOS/.github#621/#622).
#
# GitHub withholds secrets — including CLAUDE_CODE_OAUTH_TOKEN — from Dependabot-authored
# `pull_request` runs, so the required security-review gate went inert and failed CLOSED
# forever on every dep-bump PR. self-security-review.yml (and scaffold-caller.sh's template)
# fix this by ALSO triggering on `pull_request_target` (base-repo context ⇒ secrets present,
# mirroring self-automerge.yml) and routing each PR to EXACTLY ONE trigger via the job `if`:
#   • dependabot[bot]  → pull_request_target   (secrets present)
#   • everyone else    → pull_request           (unchanged; no secret-bearing context)
#
# The failure modes this guards against are (1) NO path fires for a Dependabot PR (the gate
# never reports → PR blocked, the original bug), and (2) BOTH paths fire for the same PR (the
# expensive review runs twice / a human PR reaches the privileged pull_request_target context).
#
# It extracts the ACTUAL `if` expression shipped in each stub (no hand-copied stand-in — same
# principle as test-issue-build-prereq-gating.sh) and drives it across the (event, author)
# matrix, asserting exactly one trigger fires per PR. Both the live self-security-review.yml
# stub AND the scaffold-caller.sh-emitted template are checked, so they can't drift apart.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
selfstub="$here/.github/workflows/self-security-review.yml"
scaffold="$here/scripts/scaffold-caller.sh"

command -v yq >/dev/null || { echo "FAIL: yq not on PATH" >&2; exit 1; }
command -v node >/dev/null || { echo "FAIL: node not on PATH" >&2; exit 1; }

# Emit a fresh scaffolded stub set to a temp dir so the template's routing is covered too.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash "$scaffold" -o "$tmp" -w "" >/dev/null
scaffoldstub="$tmp/security-review.yml"
[ -f "$scaffoldstub" ] || { echo "FAIL: scaffold-caller.sh did not emit security-review.yml" >&2; exit 1; }

fail=0

# ── Structural assertions: both triggers present, dependabot allowed ────────────────────────
assert_structure() {
  local label="$1" f="$2"
  local triggers allowed
  triggers="$(yq -r '.on | keys | join(",")' "$f")"
  case ",$triggers," in
    *,pull_request,*) : ;;
    *) echo "FAIL [$label]: missing 'pull_request' trigger (got: $triggers)" >&2; fail=1 ;;
  esac
  case ",$triggers," in
    *,pull_request_target,*) : ;;
    *) echo "FAIL [$label]: missing 'pull_request_target' trigger (Dependabot secrets path) (got: $triggers)" >&2; fail=1 ;;
  esac
  # ready_for_review must survive on the pull_request trigger (a skipped required check counts
  # as passing — the scaffold-caller.sh regression this file must not undo).
  yq -e '.on.pull_request.types | contains(["ready_for_review"])' "$f" >/dev/null 2>&1 \
    || { echo "FAIL [$label]: pull_request trigger lost the 'ready_for_review' type" >&2; fail=1; }
  allowed="$(yq -r '.jobs.security-review.with."allowed-bots"' "$f")"
  case ",$allowed," in
    *dependabot\[bot\]*) : ;;
    *) echo "FAIL [$label]: allowed-bots must include dependabot[bot] or claude-code-action refuses the bot PR (got: $allowed)" >&2; fail=1 ;;
  esac
}
assert_structure "self-security-review.yml" "$selfstub"
assert_structure "scaffold template" "$scaffoldstub"

# ── Behavioral assertions: drive the REAL `if` expression across the (event, author) matrix ──
# Expected routing — exactly one true per PR:
#   (pull_request,        dependabot[bot]) → false   (must NOT run here: no secrets)
#   (pull_request_target, dependabot[bot]) → true    (the fix: secrets present)
#   (pull_request,        alice)           → true    (humans unchanged)
#   (pull_request_target, alice)           → false   (humans never reach privileged context)
#   (pull_request,        suxbot[bot])     → true    (self-fixer bot PRs unchanged)
#   (pull_request_target, suxbot[bot])     → false
run_matrix() {
  local label="$1" f="$2"
  local expr
  expr="$(yq -r '.jobs.security-review.if' "$f")"
  if [ -z "$expr" ] || [ "$expr" = "null" ]; then
    echo "FAIL [$label]: no routing 'if' on the security-review job — every event would fire (double-run / privileged-context leak)" >&2
    fail=1; return
  fi
  LABEL="$label" EXPR="$expr" node <<'NODE'
const label = process.env.LABEL;
const expr = process.env.EXPR;

// Faithfulness guard: this evaluator only models the two contexts + boolean operators the
// predicate is written with. If someone rewrites it with a new signal (another github.*
// context, a function like contains()/startsWith()), fail LOUDLY rather than silently
// green — the test must be updated to model the new logic, not pass by ignoring it.
const stripped = expr
  .replace(/github\.event_name/g, "")
  .replace(/github\.event\.pull_request\.user\.login/g, "");
if (/github\./.test(stripped) || /[a-zA-Z_]+\s*\(/.test(stripped)) {
  console.error(`FAIL [${label}]: routing 'if' uses a signal this test does not model — update test-security-review-dependabot-routing.sh. expr: ${expr}`);
  process.exit(1);
}

// GitHub `==`/`!=` on two strings match JS `===`/`!==`; substitute the two contexts with the
// fixture values (JSON-quoted) and evaluate the real expression. `!=`→`!==` before `==`→`===`
// via placeholders so the `==` inside `!==` is never double-rewritten.
const fires = (eventName, login) => {
  const js = expr
    .replace(/github\.event_name/g, JSON.stringify(eventName))
    .replace(/github\.event\.pull_request\.user\.login/g, JSON.stringify(login))
    .replace(/!=/g, "@NE@").replace(/==/g, "@EQ@")
    .replace(/@NE@/g, "!==").replace(/@EQ@/g, "===");
  // eslint-disable-next-line no-new-func
  return Function(`return (${js});`)();
};

const cases = [
  ["pull_request",        "dependabot[bot]", false],
  ["pull_request_target", "dependabot[bot]", true],
  ["pull_request",        "alice",           true],
  ["pull_request_target", "alice",           false],
  ["pull_request",        "suxbot[bot]",     true],
  ["pull_request_target", "suxbot[bot]",     false],
];

let failures = 0;
for (const [ev, login, want] of cases) {
  let got;
  try { got = fires(ev, login); } catch (e) {
    console.log(`FAIL [${label}] (${ev}, ${login}): expression did not evaluate: ${e.message}`);
    failures++; continue;
  }
  if (got === want) {
    console.log(`ok   - [${label}] (${ev}, ${login}) → ${got}`);
  } else {
    console.log(`FAIL - [${label}] (${ev}, ${login}) → got ${got} want ${want}`);
    failures++;
  }
}

// Cross-cut invariant: for every author, EXACTLY ONE of the two triggers fires (no gap that
// re-creates #621/#622, no double-run). Belt-and-suspenders over the per-case table above.
for (const login of ["dependabot[bot]", "alice", "suxbot[bot]"]) {
  const n = [fires("pull_request", login), fires("pull_request_target", login)].filter(Boolean).length;
  if (n === 1) {
    console.log(`ok   - [${label}] exactly one trigger fires for ${login}`);
  } else {
    console.log(`FAIL - [${label}] ${n} triggers fire for ${login} (want exactly 1)`);
    failures++;
  }
}

if (failures) process.exit(1);
NODE
  # shellcheck disable=SC2181
  [ $? -eq 0 ] || fail=1
}
run_matrix "self-security-review.yml" "$selfstub"
run_matrix "scaffold template" "$scaffoldstub"

if [ "$fail" -eq 0 ]; then
  echo "All Dependabot security-review routing assertions passed."
else
  echo "Dependabot security-review routing assertions FAILED." >&2
fi
exit "$fail"
