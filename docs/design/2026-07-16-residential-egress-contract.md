# Residential-egress contract: schema location decision (slice-6 spike)

Tracks the vX next-arc doc (`docs/design/2026-07-16-suxos-vx-next-arc.md` §5 slice 6,
§7 item 4): the `sux` ↔ `suxrouter` residential-egress contract is today prose-only —
design docs (`ideal-router-image.md`, `router-watchdog.md`, `home-node-connectivity.md`)
in `sux`, ucode/firmware in `suxrouter`, no shared testable interface. This is the seam
most likely to silently drift (already produced the proxy empty-body incident class).
This doc records the spike's output: where the schema lives and how each side checks
against it. Full enforcement (real fixtures, real CI wiring in `sux` and `suxrouter`) is
follow-on work, filed separately once this lands.

## Decision: schema lives in `.github`

The typed contract lives at `contracts/residential-egress.schema.json` in this repo, not
in `sux` or `suxrouter`.

**Why not `sux` or `suxrouter`:** either choice makes one side authoritative over a
contract both sides must honor equally — the same asymmetry that let the prose docs
drift in the first place (nothing forced `suxrouter`'s ucode to notice when `sux`'s docs
changed, or vice versa).

**Why not `suxlib`:** `suxlib` is an npm package (`@suxos/lib`) that `sux` depends on via
`file:../suxlib`; `suxrouter` is OpenWRT ucode/firmware with no npm dependency path, so a
package-shaped home doesn't reach it.

**Why `.github`:** already the shared, org-wide home both repos' CI already trusts (every
caller repo consumes reusable workflows from here via `uses: SuxOS/.github/...`), and
it's fetchable by either side without a package manager — a raw GitHub URL or a shallow
clone, both cheap in CI. The schema's `$id` points at the `main`-branch raw URL for that
reason.

## What's in the schema

`contracts/residential-egress.schema.json` covers the five facets named in the issue:
endpoints (method/path/direction), auth (HMAC scheme), SSRF pass-through rules, host
allowlist, and status-code semantics. The `auth`, `ssrf`, and `hostAllowlist` sections are
marked `TODO` in the schema's `description` fields — this spike defines the *shape*, not
the *values*; populating them requires pulling the actual rules out of `sux`'s prose docs,
which isn't buildable from the `.github` repo alone (they live in a different repo this
job doesn't have checked out).

## The two check stubs

- `scripts/contracts/check-residential-egress-sux.stub.sh` — intended for `sux`'s CI.
  Validates recorded request/response *fixtures* against the schema (no live router call
  in CI).
- `scripts/contracts/check-residential-egress-suxrouter.stub.sh` — intended for
  `suxrouter`'s CI. Validates the *live* rpcd surface against the schema's endpoint list
  and status semantics (ucode tests can talk to a real/emulated rpcd; `sux` CI can't).

Both are `.stub.sh` — runnable today against a schema and a fixtures dir/base URL, but not
yet wired into either repo's actual CI, and not yet exercised against real sux/suxrouter
fixtures or endpoints. Wiring them in, and filling the schema's `TODO` fields from the
real prose docs, is the follow-on issue.
