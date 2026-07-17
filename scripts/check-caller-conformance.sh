#!/usr/bin/env bash
#
# Caller-stub conformance check (#346).
#
# Compares ONE repo's live SuxOS caller stubs (its .github/workflows/) against the
# canonical stub set `scripts/scaffold-caller.sh` would emit for it, surfacing the class
# of drift invariant 5 of the vX arc names (a merged reusable-workflow migration isn't
# done until every caller adopts it) — the drift that let #263 sit "fixed" for hours
# while all three caller repos still carried the dead claude-autofix `workflow_run` stub.
#
# ADVISORY by design: every finding is a `::warning::` (and a $GITHUB_STEP_SUMMARY row),
# and the script ALWAYS exits 0. It must never be able to fail a merge — same fail-safe
# posture as pin-consistency.yml's `consumers` job — so a false positive can't jam anyone's
# queue. A non-conformance is that repo's own thing to fix, surfaced here as a signal.
#
# Usage: check-caller-conformance.sh <repo-label> <consumer-workflows-dir> [self]
#
# The canonical inputs are DERIVED from this repo so they can't drift: the stub set is the
# `emit NAME` list in scripts/scaffold-caller.sh, so adding/removing a stub there updates
# this check with no edits here. Override the repo root with CALLER_CONFORMANCE_ROOT (the
# test harness points it at the real repo while feeding fixture consumer dirs).
#
# Four checks, matching the issue: (a) a canonical reusable with no live caller; (b) a
# dead/superseded stub still present (the workflow_run autofix class); (c) a present stub
# missing `secrets: inherit`, or a security-review stub missing `ready_for_review`; (d) a
# stub pinned to a stale `uses: …@ref` (first-party refs are canonically @main). It is NOT
# an exhaustive per-stub trigger diff (like test-dashboard-queries.sh isn't a full PromQL
# linter) — it covers the highest-severity, unambiguous cases.
#
# Optional 3rd arg `self` switches to .github's OWN self-*.yml caller-stub scan (#356):
# those stubs are legitimately named self-<name>[-<variant>].yml rather than <name>.yml
# (and self-fixer-30m.yml/self-fixer-bugs.yml legitimately multiplex one reusable across
# several cadence/model variants), so the naming-derived checks (a)/(c)/(d) would false-
# positive on every single one. Only the workflow_run dead-stub sub-case of (b) is
# prefix-independent — it keys off the `workflow_run:` trigger shape, not the stub's name —
# so `self` mode restricts the scan to self-*.yml files and only runs that sub-case.
MODE="full"
if [ "${3:-}" = "self" ]; then MODE="self"; fi

REPO_LABEL="${1:?usage: check-caller-conformance.sh <repo-label> <consumer-workflows-dir> [self]}"
WFDIR="${2:?usage: check-caller-conformance.sh <repo-label> <consumer-workflows-dir> [self]}"
ROOT="${CALLER_CONFORMANCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCAFFOLD="$ROOT/scripts/scaffold-caller.sh"

[ -f "$SCAFFOLD" ] || { echo "check-caller-conformance: cannot find scaffold-caller.sh at $SCAFFOLD" >&2; exit 2; }

count=0
warn() {
  echo "::warning::[$REPO_LABEL] $1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf -- '- **%s**: %s\n' "$REPO_LABEL" "$1" >> "$GITHUB_STEP_SUMMARY"; fi
  count=$((count + 1))
}

# Canonical caller-stub names = the `emit NAME` list scaffold-caller.sh writes (ground
# truth for the stub shapes). The `emit()` function definition has no space before its
# `(`, so `^emit <name>` never matches it; the commented `# emit NAME …` line starts with
# `#`, so it doesn't either.
CANON_STUBS="$(grep -oE '^emit [a-z][a-z0-9-]*' "$SCAFFOLD" | awk '{print $2}' | sort -u)"

if [ ! -d "$WFDIR" ]; then
  warn "no .github/workflows directory — no SuxOS caller stubs wired at all"
  echo "[$REPO_LABEL] conformance: $count finding(s)"
  exit 0
fi

# Every live `uses: SuxOS/.github/.github/workflows/X.yml@REF` reference across the repo,
# and the set of reusable basenames they wire.
wired="$(grep -rhoE "uses:[[:space:]]*SuxOS/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml@[A-Za-z0-9._/-]+" "$WFDIR" 2>/dev/null \
  | sed -E 's#^uses:[[:space:]]*##' | sort -u || true)"
wired_names="$(printf '%s\n' "$wired" | sed -nE 's#.*/workflows/([A-Za-z0-9._-]+)\.yml@.*#\1#p' | sort -u)"

if [ "$MODE" = "full" ]; then
  # (a) MISSING — a canonical reusable with no live caller wiring it.
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if ! printf '%s\n' "$wired_names" | grep -qxF "$c"; then
      warn "no live caller stub wires $c.yml (scaffold-caller.sh emits one — reusable adopted org-wide but not here)"
    fi
  done <<< "$CANON_STUBS"

  # (d) STALE REF — a first-party SuxOS/.github reusable wired at anything but @main.
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    ref="${u##*@}"
    name="$(printf '%s' "$u" | sed -nE 's#.*/workflows/([A-Za-z0-9._-]+)\.yml@.*#\1#p')"
    if [ "$ref" != "main" ]; then
      warn "stub wires $name.yml at @$ref — canonical first-party ref is @main (stale pinned uses:)"
    fi
  done <<< "$wired"
fi

# (b) DEAD/SUPERSEDED — a workflow FILE that wires a SuxOS reusable but whose basename is
# not in the canonical stub set. The R5/#263 class: a standalone claude-autofix.yml stub on
# `workflow_run` (autofix is job-chained inside ci.yml, never its own caller stub). In
# `self` mode this scans only self-*.yml and skips the generic non-canonical branch (see
# the usage comment above for why that branch is prefix-dependent and self-mode isn't).
if [ "$MODE" = "self" ]; then
  set -- "$WFDIR"/self-*.yml "$WFDIR"/self-*.yaml
else
  set -- "$WFDIR"/*.yml "$WFDIR"/*.yaml
fi
for f in "$@"; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"; name="${base%.*}"
  grep -qE "uses:[[:space:]]*SuxOS/\.github/\.github/workflows/" "$f" || continue
  reuses="$(grep -oE "SuxOS/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml" "$f" | sed -E 's#.*/##' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  if grep -qE '^[[:space:]]*workflow_run:' "$f"; then
    warn "dead stub '$base' triggers on workflow_run (wires: ${reuses}) — the R5/#263 class; scaffold-caller.sh never emits it (autofix is job-chained in ci.yml). Remove it."
    continue
  fi
  [ "$MODE" = "self" ] && continue
  printf '%s\n' "$CANON_STUBS" | grep -qxF "$name" && continue
  warn "non-canonical stub '$base' (wires: ${reuses}) — not in the canonical scaffold set; remove if superseded, or add to scaffold-caller.sh if intended."
done

if [ "$MODE" = "full" ]; then
  # (c) TRIGGERS/SECRETS — a present canonical stub missing `secrets: inherit`, and the
  # security-review stub missing the ready_for_review type (a skipped required check counts
  # as passing, so omitting it lets a PR go ready+merge without the review re-running —
  # scaffold-caller.sh's security-review header). Present-stub-only: a wholly missing stub is
  # already reported by (a).
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    f="$WFDIR/$c.yml"; [ -f "$f" ] || f="$WFDIR/$c.yaml"; [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*$' "$f" || \
      warn "caller stub '$c' is missing 'secrets: inherit'"
  done <<< "$CANON_STUBS"

  srf="$WFDIR/security-review.yml"; [ -f "$srf" ] || srf="$WFDIR/security-review.yaml"
  # Strip full-line comments first: scaffold-caller.sh's own stub carries a `# ready_for_review
  # is required…` note, so a bare grep would match the comment even after the trigger was dropped.
  if [ -f "$srf" ] && ! grep -vE '^[[:space:]]*#' "$srf" | grep -q 'ready_for_review'; then
    warn "security-review stub is missing the 'ready_for_review' trigger type — a skipped required check counts as passing, letting a PR go ready+merge without the review re-running (scaffold-caller.sh header)"
  fi
fi

if [ "$count" -eq 0 ]; then
  echo "[$REPO_LABEL] OK: caller stubs conform to the canonical scaffold set."
else
  echo "[$REPO_LABEL] conformance: $count advisory finding(s) above (not blocking)."
fi
exit 0
