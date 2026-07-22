# Residential-egress contract: enforcement handoff plan (#663)

Follow-on to `docs/design/2026-07-16-residential-egress-contract.md` (the slice-6 spike
that placed the schema in this repo and defined the two stub scripts). That doc already
recorded, as of the spike, that populating the schema's TODO fields and wiring the stubs
into `sux`/`suxrouter` CI is follow-on work "filed separately once this lands" — #663 is
that filed follow-up. This doc is the scoping pass for it, not the implementation: doing
the actual work requires read/write access to the `sux` and `suxrouter` repos, which a
`.github`-repo builder session does not have (`gh repo view SuxOS/sux` /
`gh api repos/SuxOS/suxrouter/...` fail from here — see the "builder session's own `gh
auth status` token" note in this repo's `CLAUDE.md`, the same limitation that has
repeatedly blocked #484/#492/#506). Nothing changed about that constraint between the
2026-07-16 spike and today, so this doc exists to make the next session (human, or an
agent invoked with cross-repo access) able to execute directly instead of re-deriving
the same plan a second time.

## Step 1 — populate the schema's TODO fields

Source each field from the named prose doc in `sux` (paths as of the original spike;
confirm they still exist before trusting them):

| Schema field | Source doc (in `sux`) | What to extract |
|---|---|---|
| `auth` (`scheme`, `headerName`, `signedFields`, `clockSkewToleranceSeconds`) | `home-node-connectivity.md` | The HMAC scheme actually implemented: header name, which fields go into the signature, and the clock-skew tolerance the verifier enforces. |
| `ssrf` (`passThroughAllowed`, `deniedTargets`) | `ideal-router-image.md` | Whether the router is ever allowed to pass through arbitrary targets, and the concrete deny-list (link-local ranges, cloud metadata IPs, etc) it enforces today. |
| `hostAllowlist` | `router-watchdog.md` | The concrete host list the router is permitted to reach/forward for on sux's behalf. |
| `endpoints` | Both `sux`'s edge/Worker code and `suxrouter`'s rpcd/ucode routes | Every HTTP(S) surface actually called across the seam today — name/method/path/direction — not aspirational ones. Cross-check both sides so the array only contains endpoints that genuinely exist on both ends. |
| `statusSemantics` | Whichever side owns the response codes for each endpoint above | The status codes each endpoint can return and whether a body is expected — this is the exact class that produced the proxy empty-body incident, so treat any ambiguity here as the highest-value field to get right. |

Do this as a single PR against `contracts/residential-egress.schema.json` in `.github`
(the schema's home, per the 2026-07-16 decision) — don't fork a copy into `sux` or
`suxrouter`. `scripts/test-residential-egress-contract.sh` (wired into `self-check.yml`)
already gates schema JSON validity and stub smoke behavior; once `endpoints` goes from
shape-only to a populated array, re-check step [4/5] and [5/5] of that script still make
sense (they currently assert specifically on the shape-only skip path and a synthetic
one-endpoint case — a real populated schema doesn't change what they test, since they
build their own synthetic fixture, but worth a read-through before assuming it still
passes unmodified).

## Step 2 — wire the sux-side stub into `sux` CI

Add a step (e.g. in `sux/.github/workflows/ci.yml`) that:

1. Checks out `SuxOS/.github` at `main` to a subpath (same pattern this repo's own
   workflows use for cross-repo script access — see the `workflow_call` checkout gotcha
   in this repo's `CLAUDE.md`): `actions/checkout@... with: {repository: SuxOS/.github,
   ref: main, path: .suxos-ci}`.
2. Installs `ajv-cli`/`ajv-formats` (the stub's own hard dependency — it errors loudly
   without them, per `check-residential-egress-sux.stub.sh`'s existing behavior).
3. Runs `bash .suxos-ci/scripts/contracts/check-residential-egress-sux.stub.sh
   <fixtures-dir>` against a fixtures directory of recorded sux edge/Worker
   request/response pairs. Those fixtures don't exist yet either — recording them
   (one JSON file per exchange, matching the shape `check-residential-egress-sux.stub.sh`
   validates) is part of this step, not a prerequisite someone else provides.

## Step 3 — wire the suxrouter-side stub into `suxrouter` CI

Add a step in `suxrouter`'s ucode test harness that:

1. Same cross-repo checkout of `SuxOS/.github` as step 2.
2. Stands up a real or emulated rpcd instance reachable at some base URL (suxrouter's
   existing ucode test infra should already have a way to do this for its own tests —
   reuse that, don't build a second one).
3. Runs `bash .suxos-ci/scripts/contracts/check-residential-egress-suxrouter.stub.sh
   <rpcd-base-url>`. Once `endpoints` is populated (step 1), this stub stops no-op
   skipping and actually probes each `sux-to-suxrouter` endpoint — verify the emulated
   rpcd responds on the real paths, not just that the stub runs without error.

## Suggested split

Steps 1–3 are three independently landable PRs across three repos (`.github`, `sux`,
`suxrouter`) rather than one PR — no ordering dependency forces them into a single
change, and each is small enough to review on its own. Step 1 should land first only
because steps 2 and 3's fixtures/live-probe checks are more useful once `endpoints` is
non-empty (that's also when `check-residential-egress-suxrouter.stub.sh` stops skipping),
but 2 and 3 can be built and merged in parallel with each other once 1 is in.

## Why this session stops here

This doc is a scoping/handoff artifact, matching the `effort:large` + "needs a
design/scoping pass first" precedent already established for #433 and #439 (see this
repo's `CLAUDE.md`). The concrete blocker is access, not complexity: none of steps 1–3
are buildable from a `.github`-only checkout, since every source-of-truth (the prose
docs, the live endpoint lists, both repos' CI configs) lives in `sux`/`suxrouter`. Filing
this as the closing artifact for #663 avoids leaving it to rot as an indefinite drop, and
gives whichever session next has `sux`/`suxrouter` access a concrete, already-derived
plan instead of re-reading the spike from scratch.
