#!/usr/bin/env bash
# Invariant gate for the residential-egress contract spike (#561, follow-on to
# docs/design/2026-07-16-residential-egress-contract.md / SuxOS/.github#... the
# slice-6 spike that shipped contracts/residential-egress.schema.json plus the
# two check-residential-egress-{sux,suxrouter}.stub.sh stubs). Until this
# script, nothing in self-check.yml touched contracts/ or scripts/contracts/ at
# all: actionlint only lints workflow YAML, and none of the other
# scripts/test-*.sh scripts reference either path — a broken schema or a stub
# with a shell bug could ship silently forever.
#
# This does NOT attempt full enforcement (that's explicitly follow-on work per
# the design doc — real fixtures/real CI wiring in sux and suxrouter). It only
# guards the two things that live in THIS repo today:
#   1. contracts/residential-egress.schema.json stays syntactically valid JSON.
#   2. Both .stub.sh scripts still run to completion (no bash syntax error, no
#      unbound-variable crash, no unhandled-command crash) against a minimal
#      trivial fixture — a smoke test, not a semantic validation of the stubs'
#      output. Neither stub is expected to *pass* in a bare CI runner (the sux
#      stub needs ajv-cli, which self-check.yml doesn't install; the suxrouter
#      stub needs a live/emulated rpcd) — both are allowed to exit non-zero via
#      their own documented, deliberate error paths. What must NOT happen is an
#      undocumented crash (e.g. exit 127/126/2, or a bash "unbound variable" /
#      "command not found" trace) that would mean the stub itself is broken.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

SCHEMA=contracts/residential-egress.schema.json
SUX_STUB=scripts/contracts/check-residential-egress-sux.stub.sh
SUXROUTER_STUB=scripts/contracts/check-residential-egress-suxrouter.stub.sh

echo "[1/3] $SCHEMA is syntactically valid JSON"
[ -f "$SCHEMA" ] || { echo "test-residential-egress-contract: cannot find $SCHEMA" >&2; exit 2; }
if jq empty "$SCHEMA" 2>/tmp/schema-jq-err.$$; then
  note "$SCHEMA parses as valid JSON"
else
  bad "$SCHEMA is not valid JSON: $(cat /tmp/schema-jq-err.$$)"
fi
rm -f /tmp/schema-jq-err.$$

echo "[1b/3] $SCHEMA looks like a JSON-Schema document (required top-level fields present)"
for key in '$schema' '$id' type required properties; do
  if jq -e --arg k "$key" 'has($k)' "$SCHEMA" >/dev/null 2>&1; then
    note "$SCHEMA has top-level '$key'"
  else
    bad "$SCHEMA is missing top-level '$key' — not a well-formed JSON-Schema document"
  fi
done
for facet in endpoints auth ssrf hostAllowlist statusSemantics; do
  if jq -e --arg f "$facet" '.required // [] | index($f)' "$SCHEMA" >/dev/null 2>&1; then
    note "$SCHEMA requires facet '$facet'"
  else
    bad "$SCHEMA no longer requires facet '$facet' — contract coverage regressed"
  fi
done

# A crash is a bash-level failure the stub's own script never intended to
# produce (missing command, unbound variable, syntax error) — as opposed to
# its own deliberate, documented `exit 1` error paths (missing ajv, unknown
# status code, etc), which are fine and expected in a bare CI runner.
assert_stub_ran_without_crashing() {
  local desc="$1" out="$2" code="$3"
  case "$code" in
    126|127|130) bad "$desc: exited $code (command-not-found/signal — looks like a real crash)"; return ;;
  esac
  if grep -qiE 'unbound variable|syntax error|: command not found|Traceback \(most recent call last\)' <<<"$out"; then
    bad "$desc: output looks like a shell/script crash, not a deliberate error path:"$'\n'"$out"
    return
  fi
  note "$desc: ran to completion (exit $code), no crash signature"
}

echo "[2/3] $SUX_STUB smoke-runs against a trivial fixture"
tmp_fixtures="$(mktemp -d)"
trap 'rm -rf "$tmp_fixtures"' EXIT
# A minimal document shaped like the full contract (the stub validates each
# fixture file against the whole schema, which requires all five facets) --
# trivial/non-exhaustive on purpose, this is a smoke test of the STUB, not a
# real conformance fixture.
cat > "$tmp_fixtures/trivial.json" <<'JSON'
{
  "endpoints": [
    { "name": "ping", "method": "GET", "path": "/ping", "direction": "sux-to-suxrouter" }
  ],
  "auth": { "scheme": "hmac-sha256" },
  "ssrf": { "passThroughAllowed": false },
  "hostAllowlist": [],
  "statusSemantics": {
    "200": { "meaning": "ok", "bodyExpected": true }
  }
}
JSON
sux_out="$(bash "$SUX_STUB" "$tmp_fixtures" 2>&1)"
sux_code=$?
assert_stub_ran_without_crashing "$SUX_STUB" "$sux_out" "$sux_code"

echo "[3/3] $SUXROUTER_STUB smoke-runs against a trivial (unreachable) rpcd base URL"
# No live/emulated rpcd is available in this repo's CI, so point at a closed
# local port: fast, deterministic connection-refused, well within the stub's
# own --max-time 10 budget -- exercises the same code path a real timeout
# would (curl failure -> "000" -> unknown status -> deliberate exit 1).
suxrouter_out="$(bash "$SUXROUTER_STUB" "http://127.0.0.1:9" 2>&1)"
suxrouter_code=$?
assert_stub_ran_without_crashing "$SUXROUTER_STUB" "$suxrouter_out" "$suxrouter_code"
# Informational only, not a fail: the stub's `.endpoints[]` walk expects the
# schema FILE to also carry literal endpoint entries at its top level, but
# contracts/residential-egress.schema.json is a pure JSON-Schema document (the
# "endpoints" key there is a `{type: array, items: {...}}` shape descriptor,
# not data) -- so `.endpoints[]` is empty against today's schema and the
# per-endpoint loop legitimately runs zero iterations. That's a known gap in
# the stub called out in the design doc as follow-on work, not something this
# smoke test's job (crash detection) should fail on.
if grep -q '^endpoint=' <<<"$suxrouter_out"; then
  note "$SUXROUTER_STUB iterated concrete endpoint entries (endpoint= line seen)"
else
  note "$SUXROUTER_STUB found no literal '.endpoints[]' entries in the schema (expected -- schema is shape-only, not instance data; see follow-on wiring note in the design doc)"
fi

if [ "$fail" -eq 0 ]; then
  echo "All residential-egress contract assertions passed."
else
  echo "residential-egress contract assertions FAILED." >&2
fi
exit "$fail"
