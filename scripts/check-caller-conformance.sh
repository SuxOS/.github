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
# Five checks, matching the issue plus #492's follow-up: (a) a canonical reusable with no
# live caller; (b) a dead/superseded stub still present (the workflow_run autofix class);
# (c) a present stub missing `secrets: inherit`, or a security-review stub missing
# `ready_for_review`; (d) a stub pinned to a stale `uses: …@ref` (first-party refs are
# canonically @main); (e) a reusable multiplexed across several canonical stub names (the
# 3-tier fixer cadence, #368) adopted via only SOME of its sibling stub files — a stale
# pre-multiplex shape that (a) alone can't see, since (a) treats any one sibling as
# sufficient adoption of the reusable. It is NOT an exhaustive per-stub trigger diff (like
# test-dashboard-queries.sh isn't a full PromQL linter) — it covers the highest-severity,
# unambiguous cases.
#
# Optional 3rd arg `self` switches to .github's OWN self-*.yml caller-stub scan (#356):
# those stubs are legitimately named self-<name>[-<variant>].yml rather than <name>.yml
# (and self-fixer-30m.yml/self-fixer-bugs.yml legitimately multiplex one reusable across
# several cadence/model variants), so the naming-derived checks (a)/(c)/(d)/(e) would
# false-positive on every single one. Only the workflow_run dead-stub sub-case of (b) is
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

# Canonical REUSABLE targets, one per `emit NAME` block — usually identical to the stub's
# own basename (ci.yml wires ci.yml, audit.yml wires audit.yml, ...), but the 3-tier fixer
# cadence (#368) multiplexes three distinctly-named stubs (fixer-bugs/fixer-30m/fixer) onto
# the SAME fixer.yml reusable. Check (a) below tests reusable ADOPTION (is fixer.yml wired
# by any of them), not per-stub-name identity, or it would warn "no live caller stub wires
# fixer-bugs.yml" forever — no stub is ever literally named that as a *reusable*, only as a
# file. Derived by taking each emit block's FIRST `uses:` line (ci.yml's block has a second,
# for the job-chained claude-autofix — deliberately not its own canonical target, same as it
# isn't its own canonical stub) so this can't drift from scaffold-caller.sh either.
CANON_TARGETS="$(awk '
  /^emit [a-z][a-z0-9-]*/ { name=$2; target=""; next }
  name != "" && target == "" && /uses: \$REPO\/\.github\/workflows\/[a-z][a-z0-9-]*\.yml@\$REF/ {
    line=$0
    sub(/.*workflows\//, "", line); sub(/\.yml@\$REF.*/, "", line)
    print line
    target=line
  }
' "$SCAFFOLD" | sort -u)"

# name<TAB>target pairs, one per `emit NAME` block (same derivation as CANON_TARGETS above,
# just keeping the name alongside instead of discarding it) — lets check (e) below group
# canonical stub NAMES by the reusable they multiplex onto.
NAME_TARGET_PAIRS="$(awk '
  /^emit [a-z][a-z0-9-]*/ { name=$2; target=""; next }
  name != "" && target == "" && /uses: \$REPO\/\.github\/workflows\/[a-z][a-z0-9-]*\.yml@\$REF/ {
    line=$0
    sub(/.*workflows\//, "", line); sub(/\.yml@\$REF.*/, "", line)
    print name"\t"line
    target=line
  }
' "$SCAFFOLD")"

if [ ! -d "$WFDIR" ]; then
  warn "no .github/workflows directory — no SuxOS caller stubs wired at all"
  echo "[$REPO_LABEL] conformance: $count finding(s)"
  exit 0
fi

# Every live `uses: SuxOS/.github/.github/workflows/X.yml@REF` reference across the repo,
# and the set of reusable basenames they wire. Full-line comments are stripped first: every
# reusable's own header carries an example `#   uses: SuxOS/.github/.github/workflows/X.yml@main`
# line, which would otherwise false-positive if this ever scans a dir containing reusable
# definitions themselves (currently moot for the cross-repo sweep, whose consumer stubs carry
# no such comments — but this keeps the check robust if that ever changes, #363). In `self`
# mode, scope this to self-*.yml only — WFDIR is the same .github/workflows this repo also
# uses for its own reusable *definitions*, and those aren't caller stubs.
if [ "$MODE" = "self" ]; then
  wired="$(for f in "$WFDIR"/self-*.yml "$WFDIR"/self-*.yaml; do [ -e "$f" ] || continue; grep -vE '^[[:space:]]*#' "$f"; done \
    | grep -oE "uses:[[:space:]]*SuxOS/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml@[A-Za-z0-9._/-]+" \
    | sed -E 's#^uses:[[:space:]]*##' | sort -u || true)"
else
  wired="$(find "$WFDIR" -type f \( -name '*.yml' -o -name '*.yaml' \) -exec grep -vE '^[[:space:]]*#' {} + 2>/dev/null \
    | grep -oE "uses:[[:space:]]*SuxOS/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml@[A-Za-z0-9._/-]+" \
    | sed -E 's#^uses:[[:space:]]*##' | sort -u || true)"
fi
wired_names="$(printf '%s\n' "$wired" | sed -nE 's#.*/workflows/([A-Za-z0-9._-]+)\.yml@.*#\1#p' | sort -u)"

if [ "$MODE" = "full" ]; then
  # (a) MISSING — a canonical reusable with no live caller wiring it.
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if ! printf '%s\n' "$wired_names" | grep -qxF "$c"; then
      warn "no live caller stub wires $c.yml (scaffold-caller.sh emits one — reusable adopted org-wide but not here)"
    fi
  done <<< "$CANON_TARGETS"

  # (e) STALE MULTIPLEX SHAPE — a reusable multiplexed across several canonical stub
  # NAMES (e.g. the 3-tier fixer cadence: fixer-bugs/fixer-30m/fixer all wiring fixer.yml,
  # #368) is "adopted" per check (a) the moment ANY one sibling stub FILE is present, so a
  # caller still on the pre-multiplex single-stub shape looks fully conformant to (a) even
  # though it's missing the other tiers entirely (#492). Flag it: for every target wired by
  # more than one canonical stub name, if at least one sibling stub FILE is present but not
  # all of them are, the missing ones are almost certainly a stale cadence, not an
  # intentional partial adopt (unlike (a), which explicitly treats one-tier as sufficient
  # adoption — this check is about completeness of an already-adopted multiplex group, not
  # adoption itself).
  targets_multi="$(printf '%s\n' "$NAME_TARGET_PAIRS" | awk -F'\t' '{print $2}' | sort | uniq -c | awk '$1>1{print $2}')"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    group="$(printf '%s\n' "$NAME_TARGET_PAIRS" | awk -F'\t' -v t="$t" '$2==t{print $1}' | sort)"
    present=""
    missing=""
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      if [ -f "$WFDIR/$c.yml" ] || [ -f "$WFDIR/$c.yaml" ]; then
        present="$present$c "
      else
        missing="$missing$c "
      fi
    done <<< "$group"
    if [ -n "$present" ] && [ -n "$missing" ]; then
      warn "wires $t.yml via stub(s) [${present% }] but is missing sibling tier stub(s) [${missing% }] — stale pre-multiplex shape (scaffold-caller.sh now emits all of: $(printf '%s\n' "$group" | tr '\n' ' ' | sed 's/ $//') for this reusable)"
    fi
  done <<< "$targets_multi"
fi

if [ "$MODE" = "full" ] || [ "$MODE" = "self" ]; then
  # (d) STALE REF — a first-party SuxOS/.github reusable wired at anything but @main. This
  # is name-independent (keys off `uses: ...@ref`, not the stub's basename), so it runs in
  # `self` mode too (#362) — unlike (a)/(c), which are derived from the canonical <name>.yml
  # stub names and would false-positive on the self-<name>.yml prefix.
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
  # Strip full-line comments before the uses: test: every reusable definition's own header
  # carries an example `#   uses: SuxOS/.github/.github/workflows/X.yml@main` line, which
  # would otherwise be mistaken for a live stub if this scan is ever widened beyond
  # self-*.yml/consumer stubs to include reusable definitions themselves (#363).
  uncommented="$(grep -vE '^[[:space:]]*#' "$f")"
  printf '%s\n' "$uncommented" | grep -qE "uses:[[:space:]]*SuxOS/\.github/\.github/workflows/" || continue
  reuses="$(printf '%s\n' "$uncommented" | grep -oE "SuxOS/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml" | sed -E 's#.*/##' | sort -u | tr '\n' ' ' | sed 's/ $//' || true)"
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
    grep -vE '^[[:space:]]*#' "$f" | grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*(#.*)?$' || \
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
