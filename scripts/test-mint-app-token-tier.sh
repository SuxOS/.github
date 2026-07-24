#!/usr/bin/env bash
# Guards the two-tier App-token model (SuxOS/.github#729).
#
# `create-github-app-token` grants the installation's ENTIRE permission set (~45 write
# permissions on the suxbot App, incl. secrets/organization_secrets/security_events/
# workflows) whenever no `permission-*` input is named. Before #729, 26 of 32
# mint-app-token call sites named none, so every model-driven builder/autofix run
# carried the full set. .github/actions/mint-app-token now takes a required `tier:`
# (`read` | `sudo`) that maps to explicit permission passthroughs, and it is the ONLY
# sanctioned way to mint a bot token in this repo.
#
# Three invariants, all of which can regress silently in a one-line diff:
#
#   1. Every mint-app-token call site passes a `tier:`. Omitting it would fail at
#      runtime (the action's Validate step), but only when that workflow next fires —
#      which for a monthly cron is a long time to sit broken.
#   2. Every `tier:` is literally `read` or `sudo`. No third tier, no per-site
#      permission map (operator decision, #729).
#   3. No workflow/action calls `actions/create-github-app-token` directly, bypassing
#      the shared action and its tier map — that is how the unscoped mint gets back in.
#      Only mint-app-token itself may reference it.
#
# Unlike test-no-new-gh-list-limit.sh's grep-based invariant, this parses the YAML
# (steps are structured data here, and a `with:` block's contents are not reliably
# greppable line-by-line), so it reports job/step names rather than line numbers and
# does not false-positive on prose or on unrelated `--permission-mode` flags.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1   # repo root (scripts/ lives directly under it)

python3 - <<'PY'
import glob
import os
import sys

import yaml

MINT = ".github/actions/mint-app-token"
VALID_TIERS = {"read", "sudo"}
fail = 0
checked = 0


def err(msg):
    global fail
    print(f"FAIL: {msg}")
    fail = 1


def steps_of(doc):
    """Yield (context, step) for every step in a workflow or composite action."""
    if not isinstance(doc, dict):
        return
    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if isinstance(step, dict):
                yield f"job '{name}'", step
    runs = doc.get("runs")
    if isinstance(runs, dict):
        for step in runs.get("steps") or []:
            if isinstance(step, dict):
                yield "runs", step


targets = sorted(glob.glob(".github/workflows/*.yml")) + sorted(
    glob.glob(".github/actions/*/action.yml")
)

for path in targets:
    with open(path) as fh:
        try:
            doc = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            err(f"{path}: unparseable YAML ({exc})")
            continue

    is_shared_action = os.path.dirname(path) == MINT

    for ctx, step in steps_of(doc):
        uses = step.get("uses")
        if not isinstance(uses, str):
            continue
        label = f"{path} ({ctx}, step '{step.get('name', uses)}')"

        # Invariant 3: nothing but the shared action may mint directly.
        if uses.split("@")[0].endswith("actions/create-github-app-token"):
            if not is_shared_action:
                err(
                    f"{label}: calls actions/create-github-app-token directly — "
                    f"use SuxOS/.github/{MINT}@main with a tier instead, so the "
                    f"token is scoped by the tier map rather than inheriting the "
                    f"App's full permission set (#729)"
                )
            continue

        if MINT not in uses.split("@")[0]:
            continue

        checked += 1
        with_ = step.get("with") or {}

        # Invariants 1 and 2.
        if "tier" not in with_:
            err(
                f"{label}: mint-app-token call site passes no `tier:` — every mint "
                f"must declare `tier: read` (cannot mutate anything) or `tier: sudo` "
                f"(write). See {MINT}/action.yml (#729)"
            )
        else:
            tier = str(with_["tier"])
            if tier not in VALID_TIERS:
                err(
                    f"{label}: invalid tier '{tier}' — must be exactly 'read' or "
                    f"'sudo'. There is no third tier (#729)"
                )

        # No per-site permission overrides: the tier map is the single source of truth.
        stray = sorted(k for k in with_ if str(k).startswith("permission-"))
        if stray:
            err(
                f"{label}: passes per-site permission override(s) {stray} — "
                f"mint-app-token no longer accepts them; the tier map in "
                f"{MINT}/action.yml is the single source of truth (#729)"
            )

if checked == 0:
    err(
        "found no mint-app-token call sites at all — the scan is looking in the wrong "
        "place (this repo has ~33), so this gate would pass vacuously"
    )

# ── The action's own Validate step ────────────────────────────────────────────────────
# `required: true` on an ACTION input is not enforced by the Actions runner (unlike a
# reusable workflow's `inputs.required`), so the shared action's Validate step is what
# actually makes the tier mandatory. Drive the real shipped shell (extracted from
# action.yml, no hand-copied stand-in) under `bash -e -c` — the runner's real default
# shell semantics per CLAUDE.md — rather than trusting it by inspection.
import subprocess

with open(f"{MINT}/action.yml") as fh:
    action = yaml.safe_load(fh)

validate = next(
    (
        s
        for s in action["runs"]["steps"]
        if isinstance(s, dict) and s.get("name") == "Validate tier"
    ),
    None,
)
if validate is None or "run" not in validate:
    err(f"{MINT}/action.yml: no 'Validate tier' step with a run: block — the required "
        f"tier is then unenforced at runtime (an action input's `required: true` is "
        f"advisory only)")
else:
    for tier, want_ok in (("read", True), ("sudo", True), ("", False), ("write", False),
                          ("READ", False), ("read sudo", False)):
        proc = subprocess.run(
            ["bash", "-e", "-c", validate["run"]],
            env={**os.environ, "TIER": tier},
            capture_output=True,
            text=True,
        )
        got_ok = proc.returncode == 0
        if got_ok != want_ok:
            err(
                f"{MINT}/action.yml Validate tier: TIER={tier!r} exited "
                f"{proc.returncode} (expected {'0' if want_ok else 'non-zero'}) — "
                f"{proc.stdout.strip()}{proc.stderr.strip()}"
            )
        if not want_ok and "::error::" not in proc.stdout:
            err(
                f"{MINT}/action.yml Validate tier: TIER={tier!r} rejected without an "
                f"::error:: annotation — the failure would be hard to spot in the run log"
            )

if fail:
    print(f"\n{checked} mint-app-token call site(s) scanned; see failures above.")
    sys.exit(1)

print(f"OK: {checked} mint-app-token call site(s), all tiered; no direct create-github-app-token calls.")
PY
