#!/usr/bin/env bash
# Unit tests for scripts/gardener/relink_dead_links.py's exact-rename dead-link repair
# (SuxOS/.github#676): unique-match repair, zero-match no-op, multi-match ambiguity no-op,
# already-resolving link untouched, and the --cap bound.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "[1/4] unique basename match gets repaired"
d="$work/unique"; mkdir -p "$d/new"
cat > "$d/Source.md" <<'EOF'
See [[archive/Target Note]] for details.
EOF
cat > "$d/new/Target Note.md" <<'EOF'
# Target Note
EOF
python3 scripts/gardener/relink_dead_links.py "$d" --cap 50 > "$work/out1.txt"
if grep -q '\[\[new/Target Note\]\]' "$d/Source.md"; then
  note "unique dead link rewritten to new/Target Note"
else
  bad "unique-match link was not repaired: $(cat "$d/Source.md")"
fi

echo "[2/4] zero matches left untouched"
d="$work/zero"; mkdir -p "$d"
cat > "$d/Source.md" <<'EOF'
See [[nowhere/Nonexistent Note]] for details.
EOF
python3 scripts/gardener/relink_dead_links.py "$d" --cap 50 > "$work/out2.txt"
if grep -q '\[\[nowhere/Nonexistent Note\]\]' "$d/Source.md"; then
  note "zero-match dead link left untouched"
else
  bad "zero-match link was unexpectedly modified: $(cat "$d/Source.md")"
fi

echo "[3/4] ambiguous (multi-match) left untouched"
d="$work/multi"; mkdir -p "$d/a" "$d/b"
cat > "$d/Source.md" <<'EOF'
See [[old/Dup]] for details.
EOF
cat > "$d/a/Dup.md" <<'EOF'
# Dup A
EOF
cat > "$d/b/Dup.md" <<'EOF'
# Dup B
EOF
python3 scripts/gardener/relink_dead_links.py "$d" --cap 50 > "$work/out3.txt"
if grep -q '\[\[old/Dup\]\]' "$d/Source.md"; then
  note "ambiguous multi-match link left untouched"
else
  bad "ambiguous link was unexpectedly modified: $(cat "$d/Source.md")"
fi

echo "[4/4] --cap bounds total repairs per run"
d="$work/cap"; mkdir -p "$d/notes"
for i in 1 2 3; do
  cat > "$d/Note$i.md" <<EOF
# Note$i
EOF
  echo "[[old$i/Note$i]]" >> "$d/Links.md"
done
python3 scripts/gardener/relink_dead_links.py "$d" --cap 2 > "$work/out4.txt"
repaired=$(grep -c '^repaired' "$work/out4.txt" || true)
total_line=$(grep '^gardener relink:' "$work/out4.txt")
if echo "$total_line" | grep -q '^gardener relink: 2 repair'; then
  note "cap of 2 honored ($total_line)"
else
  bad "expected exactly 2 repairs under --cap 2, got: $total_line"
fi

if [ "$fail" -eq 0 ]; then
  echo "All gardener relink tests passed."
else
  echo "One or more gardener relink tests FAILED." >&2
fi
exit "$fail"
