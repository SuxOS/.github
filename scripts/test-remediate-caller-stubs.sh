#!/usr/bin/env bash
#
# Unit-tests scripts/remediate-caller-stubs.sh (#355).
#
# Same fixture strategy as test-caller-conformance.sh: the "healthy" tree comes from the
# REAL scaffold-caller.sh so it can never drift from the canonical stub set, and each case
# mutates a copy of it. remediate-caller-stubs.sh always exits 0; assertions are on the
# resulting filesystem state, not its exit code.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
export CALLER_CONFORMANCE_ROOT="$here"
remediate="$here/scripts/remediate-caller-stubs.sh"
scaffold="$here/scripts/scaffold-caller.sh"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

healthy="$tmproot/healthy"
mkdir -p "$healthy"
bash "$scaffold" -o "$healthy" -w "" >/dev/null

fresh_copy() { # fresh_copy NAME -> echoes a path to a fresh mutable copy of the healthy tree
  local dst="$tmproot/$1"
  rm -rf "$dst"; cp -r "$healthy" "$dst"
  echo "$dst"
}

failures=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; shift; printf '%s\n' "$@" | sed 's/^/        /'; failures=$((failures + 1)); }

# 1. A tree that already conforms: remediation must be a no-op (no files added/removed/changed).
d="$(fresh_copy already-healthy)"
before="$(find "$d" -type f | sort | xargs -I{} sh -c 'echo {}; cat {}' | sha256sum)"
out="$(bash "$remediate" "$d" 2>&1)"
after="$(find "$d" -type f | sort | xargs -I{} sh -c 'echo {}; cat {}' | sha256sum)"
if [ "$before" = "$after" ]; then ok "healthy tree untouched"; else bad "healthy tree untouched" "$out"; fi

# 2. (a) MISSING canonical stub — dropped, then remediated back.
d="$(fresh_copy missing-audit)"; rm -f "$d/audit.yml"
bash "$remediate" "$d" >/dev/null
if [ -f "$d/audit.yml" ] && grep -q 'workflows/audit.yml@main' "$d/audit.yml"; then
  ok "(a) missing canonical stub (audit) re-added"
else
  bad "(a) missing canonical stub (audit) re-added" "audit.yml not restored"
fi

# 3. An EXISTING stub is never overwritten, even if hand-customized (scaffold-caller.sh's
#    own emit() skip-if-exists behavior — remediation must inherit it, not force).
d="$(fresh_copy customized-health)"
printf '# hand customization marker\n' >> "$d/health.yml"
bash "$remediate" "$d" >/dev/null
if grep -q 'hand customization marker' "$d/health.yml"; then
  ok "existing customized stub left untouched"
else
  bad "existing customized stub left untouched" "customization marker lost"
fi

# 4. ci.yml specifically is NEVER auto-added even when wholly missing — its
#    --wrangler-config default may not fit every caller's layout (CLAUDE.md caller-list
#    guard). Remediation must revert scaffold-caller.sh's default add of it.
d="$(fresh_copy missing-ci)"; rm -f "$d/ci.yml"
bash "$remediate" "$d" >/dev/null
if [ ! -f "$d/ci.yml" ]; then
  ok "ci.yml not auto-added when missing"
else
  bad "ci.yml not auto-added when missing" "ci.yml was (re-)created"
fi

# 5. (b) DEAD workflow_run stub — the R5/#263 class — is removed outright.
d="$(fresh_copy dead-autofix)"
cat > "$d/claude-autofix.yml" <<'YAML'
name: Claude autofix
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  autofix:
    uses: SuxOS/.github/.github/workflows/claude-autofix.yml@main
    secrets: inherit
YAML
bash "$remediate" "$d" >/dev/null
if [ ! -f "$d/claude-autofix.yml" ]; then
  ok "(b) dead workflow_run stub removed"
else
  bad "(b) dead workflow_run stub removed" "claude-autofix.yml still present"
fi

# 6. A non-canonical stub NOT on workflow_run is left alone — that softer case needs a
#    human judgment call (intentional bespoke workflow vs. superseded stub), so
#    remediation must not touch it.
d="$(fresh_copy bespoke)"
cat > "$d/bespoke.yml" <<'YAML'
name: Bespoke
on:
  push:
jobs:
  x:
    uses: SuxOS/.github/.github/workflows/health.yml@main
    secrets: inherit
YAML
bash "$remediate" "$d" >/dev/null
if [ -f "$d/bespoke.yml" ]; then
  ok "non-workflow_run non-canonical stub left for human judgment"
else
  bad "non-workflow_run non-canonical stub left for human judgment" "bespoke.yml was removed"
fi

# 7. ci.yml legitimately job-chains claude-autofix.yml (autofix job on pull_request, not
#    workflow_run) — must not be mistaken for a dead stub and removed.
d="$(fresh_copy job-chained-ci)"
bash "$remediate" "$d" >/dev/null
if [ -f "$d/ci.yml" ]; then
  ok "job-chained ci.yml (autofix job) not mistaken for a dead stub"
else
  bad "job-chained ci.yml (autofix job) not mistaken for a dead stub" "ci.yml was removed"
fi

# 8. An empty/all-comment stub file must not abort the script under set -e (#430) — a
#    realistic operator placeholder/disabled-workflow stub.
d="$(fresh_copy empty-stub)"
: > "$d/placeholder.yml"
printf '# disabled for now\n# nothing to see here\n' > "$d/commented-out.yml"
out="$(bash "$remediate" "$d" 2>&1)"
if [ -f "$d/placeholder.yml" ] && [ -f "$d/commented-out.yml" ]; then
  ok "empty/all-comment stub files don't abort remediation"
else
  bad "empty/all-comment stub files don't abort remediation" "$out"
fi

# 9. (d) STALE @ref — a first-party SuxOS/.github stub pinned to something other than
#    @main is rewritten in place to @main (#432).
d="$(fresh_copy stale-ref)"
cat > "$d/health.yml" <<'YAML'
name: Health
on:
  schedule:
    - cron: "*/15 * * * *"
jobs:
  health:
    uses: SuxOS/.github/.github/workflows/health.yml@abc1234
    secrets: inherit
YAML
bash "$remediate" "$d" >/dev/null
if grep -q 'workflows/health.yml@main' "$d/health.yml" && ! grep -q '@abc1234' "$d/health.yml"; then
  ok "(d) stale @ref pin rewritten to @main"
else
  bad "(d) stale @ref pin rewritten to @main" "$(cat "$d/health.yml")"
fi

# 10. A stub already pinned to @main is left byte-identical (no spurious rewrite).
d="$(fresh_copy already-main)"
before="$(sha256sum "$d/health.yml")"
bash "$remediate" "$d" >/dev/null
after="$(sha256sum "$d/health.yml")"
if [ "$before" = "$after" ]; then
  ok "stub already pinned to @main left untouched"
else
  bad "stub already pinned to @main left untouched" "content changed"
fi

if [ "$failures" -gt 0 ]; then echo; echo "$failures assertion(s) failed"; exit 1; fi
echo; echo "all remediate-caller-stubs assertions passed"
