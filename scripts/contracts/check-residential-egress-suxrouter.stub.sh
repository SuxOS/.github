#!/usr/bin/env bash
# STUB — slice-6 spike output, not yet wired into suxrouter's CI.
#
# Intended home: suxrouter's own CI (its ucode test harness), asserting the
# LIVE rpcd surface (endpoints, auth/HMAC header, status codes) matches the
# shared contract in contracts/residential-egress.schema.json (this repo).
# Unlike the sux-side stub (which checks recorded fixtures), this one talks
# to a real or emulated rpcd instance, since suxrouter's tests run against
# actual ucode/firmware rather than replayable request fixtures.
#
# Usage once adopted: check-residential-egress-suxrouter.stub.sh <rpcd-base-url>
# For each endpoint in the schema, issue the call and assert the response
# status is one of the codes listed in "statusSemantics".
#
# Full enforcement (real rpcd probes, real CI wiring) is follow-on to this spike.
set -euo pipefail

SCHEMA="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/contracts/residential-egress.schema.json"
RPCD_BASE_URL="${1:?usage: $0 <rpcd-base-url>}"

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq not found" >&2
  exit 1
fi

status=0
while IFS= read -r endpoint; do
  name=$(jq -r '.name' <<< "$endpoint")
  method=$(jq -r '.method' <<< "$endpoint")
  path=$(jq -r '.path' <<< "$endpoint")
  direction=$(jq -r '.direction' <<< "$endpoint")
  if [ "$direction" != "sux-to-suxrouter" ]; then
    continue
  fi
  got=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X "$method" "${RPCD_BASE_URL}${path}" || echo "000")
  known=$(jq --arg code "$got" 'has($code)' <<< "$(jq '.statusSemantics' "$SCHEMA")")
  echo "endpoint=$name method=$method path=$path got=$got known_status=$known"
  [ "$known" = "true" ] || status=1
done < <(jq -c '.endpoints[]' "$SCHEMA")

exit "$status"
