#!/usr/bin/env bash
# Coverage gate for contracts/residential-egress.schema.json and its two
# scripts/contracts/check-residential-egress-*.stub.sh scripts (SuxOS/.github#561).
#
# Nothing in this repo validated these artifacts before: self-check.yml's
# actionlint step only lints workflow YAML, and none of the scripts/test-*.sh
# invariant scripts touched contracts/ or scripts/contracts/ at all. A typo
# breaking the schema's JSON syntax, or a bug in either stub script, shipped
# silently on every merge — caught only much later, if at all, by whichever
# caller repo actually tried to consume it. This script (a) validates the
# schema is syntactically valid JSON/JSON-Schema and (b) smoke-runs each stub
# script against a trivial fixture, with fake `ajv`/`curl` shims on PATH so
# no network or real toolchain is required.
#
# Wired into self-check.yml by name (the repo's explicit-not-glob convention).
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)

SCHEMA="$(pwd)/contracts/residential-egress.schema.json"
SUX_STUB="$(pwd)/scripts/contracts/check-residential-egress-sux.stub.sh"
SUXROUTER_STUB="$(pwd)/scripts/contracts/check-residential-egress-suxrouter.stub.sh"

fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "[1/5] schema is syntactically valid JSON"
if jq empty "$SCHEMA" 2>/tmp/schema-jq-err; then
  note "contracts/residential-egress.schema.json parses"
else
  bad "schema JSON syntax error: $(cat /tmp/schema-jq-err)"
fi

echo "[2/5] schema is shaped like a JSON Schema (type/properties/required present)"
shape_ok=$(jq -r 'if (.type == "object") and (.properties | type == "object") and (.required | type == "array") then "yes" else "no" end' "$SCHEMA" 2>/dev/null || echo "no")
if [ "$shape_ok" = "yes" ]; then
  note "top-level type/properties/required look sane"
else
  bad "schema missing expected top-level type/properties/required shape"
fi

# --- sux stub: fake ajv-cli on PATH, no real ajv/network needed ---
fakebin="$tmp/bin"
mkdir -p "$fakebin" "$tmp/fixtures"
echo '{"example": "fixture"}' > "$tmp/fixtures/trivial.json"
cat > "$fakebin/ajv" <<'EOF'
#!/usr/bin/env bash
# fake ajv-cli: accepts `validate -s SCHEMA -d FIXTURE` and always succeeds
[ "$1" = "validate" ] && exit 0
exit 1
EOF
chmod +x "$fakebin/ajv"

echo "[3/5] sux stub smoke-runs against a trivial fixture"
out=$(PATH="$fakebin:$PATH" bash "$SUX_STUB" "$tmp/fixtures" 2>&1)
code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q "checking $tmp/fixtures/trivial.json"; then
  note "sux stub runs the fixture through ajv and exits 0"
else
  bad "sux stub fixture run: expected exit 0 + fixture line, got exit=$code out=$out"
fi

echo "[3b/5] sux stub fails closed when ajv-cli is missing"
out=$(PATH="/usr/bin:/bin" bash "$SUX_STUB" "$tmp/fixtures" 2>&1)
code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q '::error::ajv-cli not found'; then
  note "sux stub errors loudly without ajv-cli"
else
  bad "sux stub missing-ajv case: expected exit 1 + ::error::, got exit=$code out=$out"
fi

# --- suxrouter stub: real schema has no endpoint instances yet -> graceful skip ---
echo "[4/5] suxrouter stub no-ops cleanly against the current (shape-only) schema"
out=$(bash "$SUXROUTER_STUB" "http://127.0.0.1:1" 2>&1)
code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q "skipping"; then
  note "suxrouter stub skips gracefully with no endpoint instances"
else
  bad "suxrouter stub shape-only schema: expected exit 0 + skip message, got exit=$code out=$out"
fi

# --- suxrouter stub: synthetic schema WITH one endpoint instance + fake curl ---
echo "[5/5] suxrouter stub smoke-runs one endpoint against a fake rpcd"
synth_schema="$tmp/synthetic-schema.json"
jq '. + {
      endpoints: [{name: "ping", method: "GET", path: "/ping", direction: "sux-to-suxrouter"}],
      statusSemantics: {"200": {"meaning": "ok"}}
    }' "$SCHEMA" > "$synth_schema"

synth_dir="$tmp/synth-repo/contracts"
mkdir -p "$synth_dir" "$tmp/synth-repo/scripts/contracts"
cp "$synth_schema" "$synth_dir/residential-egress.schema.json"
cp "$SUXROUTER_STUB" "$tmp/synth-repo/scripts/contracts/"

fakecurl="$fakebin/curl"
cat > "$fakecurl" <<'EOF'
#!/usr/bin/env bash
# fake curl: always reports 200, matching the synthetic statusSemantics above
for a in "$@"; do :; done
echo -n "200"
EOF
chmod +x "$fakecurl"

out=$(PATH="$fakebin:$PATH" bash "$tmp/synth-repo/scripts/contracts/check-residential-egress-suxrouter.stub.sh" "http://127.0.0.1:1" 2>&1)
code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q "endpoint=ping" && printf '%s' "$out" | grep -q "known_status=true"; then
  note "suxrouter stub matches a known status against a synthetic endpoint"
else
  bad "suxrouter stub synthetic endpoint: expected exit 0 + known_status=true, got exit=$code out=$out"
fi

if [ "$fail" -eq 0 ]; then
  echo "all residential-egress contract checks passed"
else
  echo "residential-egress contract checks FAILED" >&2
fi
exit "$fail"
