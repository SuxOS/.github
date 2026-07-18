#!/usr/bin/env bash
# Unit-tests gh-list-exhaustive's growth/cap-detection loop
# (.github/actions/gh-list-exhaustive/action.yml, SuxOS/.github#396) against a
# fake `gh`, with no network. This is the shared helper extracted to retire
# the "gh ... list --limit N then filter" undercount bug class fixed ad hoc at
# #18, #247, #344, #345, #350, #366: it must return the TRUE full result set
# (paging past a single bounded call) or fail loud, never silently truncate.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

run=$(yq -r '.runs.steps[] | select(.id == "list") | .run' .github/actions/gh-list-exhaustive/action.yml)

# Fake `gh` that returns min(TOTAL, requested --limit) numbered items, so it
# behaves like a real capped list endpoint.
make_fake_gh() {
  local dir="$1" total="$2" fail_mode="${3:-}"
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
if [ "$fail_mode" = "error" ]; then exit 1; fi
limit=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--limit" ]; then limit="\$a"; fi
  prev="\$a"
done
python3 -c "
import json
n = min($total, \$limit)
print(json.dumps([{'number': i} for i in range(n)]))
"
EOF
  chmod +x "$dir/gh"
}

echo "[1/4] single page (result well under start-limit)"
d1=$(mktemp -d); make_fake_gh "$d1" 3
out1=/tmp/gh-list-exhaustive-out.$$
: > "$out1"
PATH="$d1:$PATH" GITHUB_OUTPUT="$out1" ARGS=$'pr\nlist' JSON_FIELDS=number START_LIMIT=100 MAX_LIMIT=6400 \
  bash -c "$run" >/dev/null 2>&1
if grep -q '^count=3$' "$out1"; then
  note "small result returns in one call (count=3)"
else
  bad "expected count=3, got: $(cat "$out1")"
fi
rm -rf "$d1" "$out1"

echo "[2/4] growth required (250 results, start-limit=100)"
d2=$(mktemp -d); make_fake_gh "$d2" 250
out2=/tmp/gh-list-exhaustive-out.$$
: > "$out2"
PATH="$d2:$PATH" GITHUB_OUTPUT="$out2" ARGS=$'pr\nlist' JSON_FIELDS=number START_LIMIT=100 MAX_LIMIT=6400 \
  bash -c "$run" >/dev/null 2>&1
if grep -q '^count=250$' "$out2"; then
  note "grows past a short first page to the true full count (count=250)"
else
  bad "expected count=250 (an undetected cap would truncate to 100), got: $(cat "$out2")"
fi
rm -rf "$d2" "$out2"

echo "[3/4] result set exceeds max-limit -> fails loud, does not return a truncated result"
d3=$(mktemp -d); make_fake_gh "$d3" 999999
out3=/tmp/gh-list-exhaustive-out.$$
: > "$out3"
rc=0
err=$(PATH="$d3:$PATH" GITHUB_OUTPUT="$out3" ARGS=$'pr\nlist' JSON_FIELDS=number START_LIMIT=100 MAX_LIMIT=6400 \
  bash -c "$run" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q '::error::' && ! grep -q '^json=' "$out3"; then
  note "refuses to silently return a truncated result once max-limit is exceeded"
else
  bad "did not fail loud on an uncapped result set (rc=$rc, err=$err, output=$(cat "$out3"))"
fi
rm -rf "$d3" "$out3"

echo "[4/4] gh error surfaces as ::error:: and a non-zero exit"
d4=$(mktemp -d); make_fake_gh "$d4" 0 error
out4=/tmp/gh-list-exhaustive-out.$$
: > "$out4"
rc=0
err=$(PATH="$d4:$PATH" GITHUB_OUTPUT="$out4" ARGS=$'pr\nlist' JSON_FIELDS=number START_LIMIT=100 MAX_LIMIT=6400 \
  bash -c "$run" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q '::error::'; then
  note "a gh failure surfaces as ::error:: and a non-zero exit"
else
  bad "a gh failure did not surface as expected (rc=$rc, output: $err)"
fi
rm -rf "$d4" "$out4"

if [ "$fail" -eq 0 ]; then
  echo "gh-list-exhaustive regression guard: PASS"
else
  echo "gh-list-exhaustive regression guard: FAIL"
  exit 1
fi
