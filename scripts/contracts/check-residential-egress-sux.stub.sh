#!/usr/bin/env bash
# STUB — slice-6 spike output, not yet wired into sux's CI.
#
# Intended home: sux's own CI (e.g. a step in sux/.github/workflows/ci.yml),
# validating fixtures RECORDED from sux's edge/Worker code against the shared
# contract in contracts/residential-egress.schema.json (this repo). sux does
# not call suxrouter's live rpcd in CI — it asserts its own request/response
# fixtures still match the schema, so drift is caught without a live router.
#
# Usage once adopted: check-residential-egress-sux.stub.sh <fixtures-dir>
# where <fixtures-dir> holds one JSON file per recorded exchange, each
# validated against the "endpoints"/"statusSemantics" shapes in the schema.
#
# Full enforcement (real fixtures, real CI wiring) is follow-on to this spike.
set -euo pipefail

SCHEMA="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/contracts/residential-egress.schema.json"
FIXTURES_DIR="${1:?usage: $0 <fixtures-dir>}"

if ! command -v ajv >/dev/null 2>&1; then
  echo "::error::ajv-cli not found — install with 'npm install -g ajv-cli ajv-formats'" >&2
  exit 1
fi

status=0
for fixture in "$FIXTURES_DIR"/*.json; do
  [ -e "$fixture" ] || { echo "no fixtures found in $FIXTURES_DIR"; break; }
  echo "checking $fixture against $SCHEMA"
  ajv validate -s "$SCHEMA" -d "$fixture" || status=1
done

exit "$status"
