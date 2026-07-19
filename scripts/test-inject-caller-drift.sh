#!/usr/bin/env bash
#
# Unit-tests scripts/inject-caller-drift.sh (#490 slice 2) end-to-end against the REAL
# check-caller-conformance.sh: inject each known drift class into a healthy scaffolded tree,
# assert the check flags it, revert, assert clean again. This is the same inject-scan-assert-
# revert cycle #490's (still-unbuilt) scheduled canary job would run against a live repo —
# proving the primitive itself is correct before it ever touches one.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
export CALLER_CONFORMANCE_ROOT="$here"
inject="$here/scripts/inject-caller-drift.sh"
check="$here/scripts/check-caller-conformance.sh"
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
assert_clean() { # assert_clean LABEL DIR
  local label="$1" dir="$2" out
  out="$(bash "$check" "$label" "$dir" 2>&1)"
  if printf '%s\n' "$out" | grep -q '::warning::'; then
    echo "FAIL - $label (expected no warnings)"; printf '%s\n' "$out" | sed 's/^/        /'
    failures=$((failures + 1))
  else
    echo "ok   - $label"
  fi
}
assert_warns() { # assert_warns LABEL DIR PATTERN
  local label="$1" dir="$2" pat="$3" out
  out="$(bash "$check" "$label" "$dir" 2>&1)"
  if printf '%s\n' "$out" | grep -qE "$pat"; then
    echo "ok   - $label"
  else
    echo "FAIL - $label (expected a warning matching: $pat)"; printf '%s\n' "$out" | sed 's/^/        /'
    failures=$((failures + 1))
  fi
}

echo "[1/3] MISSING drift class: inject removes audit.yml, revert restores it"
d="$(fresh_copy missing)"
bash "$inject" "$d" inject missing-stub audit >/dev/null
assert_warns "missing-stub: injected drift is flagged" "$d" "no live caller stub wires audit\.yml"
bash "$inject" "$d" revert missing-stub audit >/dev/null
assert_clean "missing-stub: reverted tree is clean again" "$d"

echo "[2/3] DEAD drift class: inject adds a workflow_run claude-autofix.yml, revert removes it"
d="$(fresh_copy dead)"
bash "$inject" "$d" inject dead-stub >/dev/null
assert_warns "dead-stub: injected drift is flagged" "$d" "dead stub 'claude-autofix\.yml' triggers on workflow_run"
bash "$inject" "$d" revert dead-stub >/dev/null
assert_clean "dead-stub: reverted tree is clean again" "$d"
if bash "$inject" "$d" revert dead-stub >/dev/null 2>&1; then
  echo "FAIL - dead-stub: revert without a prior inject should refuse (nothing to revert)"
  failures=$((failures + 1))
else
  echo "ok   - dead-stub: revert without a prior inject refuses (no double-revert)"
fi

echo "[3/3] STALE-REF drift class: inject pins audit.yml off @main, revert restores @main"
d="$(fresh_copy stale)"
bash "$inject" "$d" inject stale-ref audit >/dev/null
assert_warns "stale-ref: injected drift is flagged" "$d" "stub wires audit\.yml at @v0\.0\.0-chaos-test"
bash "$inject" "$d" revert stale-ref audit >/dev/null
assert_clean "stale-ref: reverted tree is clean again" "$d"

echo "[extra] guards: double-inject and wrong-marker deletes are refused"
d="$(fresh_copy guards)"
bash "$inject" "$d" inject missing-stub audit >/dev/null
if bash "$inject" "$d" inject missing-stub audit >/dev/null 2>&1; then
  echo "FAIL - missing-stub: double-inject (already removed) should refuse"
  failures=$((failures + 1))
else
  echo "ok   - missing-stub: double-inject refuses (file already gone)"
fi
d="$(fresh_copy guards2)"
# A real (non-injected) claude-autofix-shaped file must never be deleted by revert dead-stub —
# only ever content this script itself wrote (marker-gated).
cat > "$d/claude-autofix.yml" <<'YAML'
name: Not our injection
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  autofix:
    uses: SuxOS/.github/.github/workflows/claude-autofix.yml@main
    secrets: inherit
YAML
if bash "$inject" "$d" revert dead-stub >/dev/null 2>&1; then
  echo "FAIL - dead-stub: revert must refuse to delete a non-injected claude-autofix.yml"
  failures=$((failures + 1))
else
  echo "ok   - dead-stub: revert refuses to delete a file it didn't inject (marker check)"
fi

if [ "$failures" -gt 0 ]; then echo; echo "$failures assertion(s) failed"; exit 1; fi
echo; echo "all inject-caller-drift assertions passed"
