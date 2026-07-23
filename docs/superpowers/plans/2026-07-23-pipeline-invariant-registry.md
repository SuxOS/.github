# Pipeline Invariant Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the invariant registry from `docs/design/2026-07-23-pipeline-invariant-registry-design.md` — a fabric-health-hosted set of `drift`/`ttl`/`effect` checks that surface silent-green, never-self-heals, and drift failures in ~15 minutes instead of hours, with one bounded auto-remediation (`disable-workflow`).

**Architecture:** A read-only Python runner (`invariants/runner.py`) evaluates declarative `drift`/`ttl` manifest entries and discovers `invariants/effect/*.py` scripts, emitting one normalized JSON result set. All mutation (needs-human alert upsert, `gh workflow disable` remediation) lives in new `fabric-health.yml` steps that consume that JSON. Metrics ride the existing Grafana push; alerts ride the existing needs-human rollup.

**Tech Stack:** Python 3 stdlib only (manifest arrives as JSON via `yq -o=json`), bash + `jq`/`yq` for workflow steps and tests, `gh` CLI for all GitHub reads/writes, extraction-tested with fake-binary PATH shims per this repo's `scripts/test-*.sh` convention.

**Prerequisite:** PR #712 (the design doc + this plan) merged to `main` of `SuxOS/.github`. All implementation work happens on a fresh branch off `main`, landing via PR (org ruleset: PR + security-review required).

## Global Constraints

- Repo: `SuxOS/.github`. Every workflow edit ships to every caller repo simultaneously — check `inputs:` defaults against all callers (`sux`, `suxrouter`, `claude-config`, `suxlib`, `suxdash`, `suxos-net`, `nix`) before changing them (repo CLAUDE.md).
- Gate: `self-check.yml` (actionlint + shellcheck over embedded `run:` blocks, plus `scripts/test-*.sh` invariant scripts wired **by explicit step name, not glob**). Every new test script in this plan gets its own step there, in the same task that creates the script.
- Collection-integrity contract (#305): no query may fail-silent to a healthy-looking value. In this plan that means: manifest `live`/`declared` snippets run under `bash -euo pipefail` and a nonzero exit becomes CRIT; effect scripts exit 2 on "couldn't measure"; the alert-upsert step skips (with `::warning::`) rather than acting on an unfetchable issue list.
- Design §7 error contract: a check that cannot run (crash, timeout, non-numeric output) is reported CRIT with the error text — never skipped. Only an unusable manifest makes the runner exit nonzero (failing the workflow step loudly).
- The runner is **read-only**. Mutations live only in `fabric-health.yml` steps.
- Effect script contract (design §4.2): exit 0/1/2 = OK/WARN/CRIT, first stdout line is the message.
- Dormant-until-secrets contract: anything needing a new secret (`GRAFANA_PROM_QUERY_*`) no-ops with an explicit "inert" message when unset, exactly like the existing Grafana push.
- v1 remediation constraint: `remediate.action` = `disable-workflow` only, `remediate.repo` = `SuxOS/.github` only (the workflow `GITHUB_TOKEN` is repo-scoped and cannot disable cross-repo). Lint-enforced.
- New `fabric-health.yml` steps must keep `${{ }}` expressions OUT of `run:` bodies (env-var indirection only) so `yq`-extraction tests can execute them verbatim — the same property the existing `collect` step has.
- Date math in manifest snippets and tests must use the dual GNU/BSD form already used in `fabric-health.yml` (`date -u -d ... 2>/dev/null || date -u -v...`) so tests run on both macOS (local) and ubuntu (CI).
- All `gh` calls in workflow steps use `${{ secrets.GITHUB_TOKEN }}` (the bot identity) — never a personal token.
- Commit style: conventional (`feat:`, `fix:`, `test:`, `docs:`) matching `git log`.

## File Structure

| File | Responsibility |
|---|---|
| `invariants/manifest.yml` (create) | Declarative `drift`/`ttl` entries — data, no code |
| `invariants/runner.py` (create) | Load manifest JSON, evaluate drift/ttl, run effect scripts, emit normalized JSON. Read-only |
| `invariants/effect/cost_effectiveness.py` (create) | Effect check: spend-without-output (#701 broad signature) |
| `invariants/effect/grafana_push_verify.py` (create) | Effect check: Grafana push round-trip (#694) |
| `scripts/check-invariants-manifest.sh` (create) | Manifest schema lint (the contribution rule's enforceable slice) |
| `scripts/test-invariants-runner.sh` (create) | Runner drift/ttl semantics tests |
| `scripts/test-invariants-effect-contract.sh` (create) | Effect discovery/contract/crash/timeout tests |
| `scripts/test-invariants-manifest.sh` (create) | Lint logic tests + real-manifest offline smoke |
| `scripts/test-invariants-effect-checks.sh` (create) | The two real effect scripts, tested via PATH shims |
| `scripts/test-fabric-health-invariants.sh` (create) | Extraction tests: CRIT→alert path, CRIT+remediate→disable path |
| `.github/workflows/fabric-health.yml` (modify) | Three new steps + metrics append + `actions: write` + timeout bump |
| `.github/workflows/self-fabric-health.yml` (modify) | `actions: write` on the spine job |
| `.github/workflows/self-check.yml` (modify) | Wire each new script (one step per script, added per task) |
| `README.md` (modify) | New optional secrets + invariants section |

---

### Task 1: Runner core — drift/ttl evaluation

**Files:**
- Create: `invariants/runner.py`
- Create: `scripts/test-invariants-runner.sh`
- Modify: `.github/workflows/self-check.yml` (add one step)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: CLI `python3 invariants/runner.py --manifest <json-file> [--effect-dir DIR] [--timeout SECONDS]` → stdout JSON `{"schema": "suxos-invariants-result/v1", "results": [{"id", "kind", "severity", "status", "message", "remediate"}]}`; exit 0 when results were produced (even all-CRIT), exit 1 only on an unusable manifest. `--effect-dir` is accepted but implemented in Task 2. Statuses are `OK`/`WARN`/`CRIT`; `remediate` is the manifest object passed through verbatim or `null`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Tests invariants/runner.py's drift/ttl evaluation semantics against fixture
# manifests (design docs/design/2026-07-23-pipeline-invariant-registry-design.md
# §4.3): ttl live>bound trips, drift eq/le mismatch trips, severity warn maps to
# WARN, and — the §7 error contract — a failing/timeout/non-numeric live query is
# CRIT (never OK, never skipped), while an unusable manifest exits nonzero.
# Fixture `live` snippets are plain echo/exit, so this runs offline, no gh needed.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

run_runner() {  # $1 = manifest json; prints stdout, returns runner's exit code
  python3 invariants/runner.py --manifest "$1"
}

# --- ttl semantics ---
cat > "$tmp/ttl.json" <<'EOF'
{"schema": "suxos-invariants/v1", "checks": [
  {"id": "under", "kind": "ttl", "description": "d", "bound": 5, "live": "echo 3"},
  {"id": "over",  "kind": "ttl", "description": "d", "bound": 5, "live": "echo 9",
   "remediate": {"action": "disable-workflow", "repo": "SuxOS/.github", "workflow": "x.yml"}},
  {"id": "warn-over", "kind": "ttl", "severity": "warn", "description": "d", "bound": 0, "live": "echo 1"}
]}
EOF
out=$(run_runner "$tmp/ttl.json") || bad "runner exited nonzero on a valid manifest"
[ "$(jq -r '.results[] | select(.id=="under") | .status' <<<"$out")" = "OK" ] \
  && note "ttl under bound is OK" || bad "ttl under bound should be OK"
[ "$(jq -r '.results[] | select(.id=="over") | .status' <<<"$out")" = "CRIT" ] \
  && note "ttl over bound is CRIT" || bad "ttl over bound should be CRIT"
[ "$(jq -r '.results[] | select(.id=="over") | .remediate.workflow' <<<"$out")" = "x.yml" ] \
  && note "remediate passes through" || bad "remediate should pass through to output"
[ "$(jq -r '.results[] | select(.id=="warn-over") | .status' <<<"$out")" = "WARN" ] \
  && note "severity warn trips to WARN" || bad "severity warn should trip to WARN"

# --- drift semantics ---
cat > "$tmp/drift.json" <<'EOF'
{"schema": "suxos-invariants/v1", "checks": [
  {"id": "eq-match",    "kind": "drift", "description": "d", "declared": "echo a", "live": "echo a"},
  {"id": "eq-mismatch", "kind": "drift", "description": "d", "declared": "echo a", "live": "echo b"},
  {"id": "le-ok",       "kind": "drift", "description": "d", "compare": "le", "declared": "echo 60", "live": "echo 12"},
  {"id": "le-tripped",  "kind": "drift", "description": "d", "compare": "le", "declared": "echo 60", "live": "echo 99"}
]}
EOF
out=$(run_runner "$tmp/drift.json") || bad "runner exited nonzero on drift manifest"
[ "$(jq -r '.results[] | select(.id=="eq-match") | .status' <<<"$out")" = "OK" ] \
  && note "drift eq match is OK" || bad "drift eq match should be OK"
[ "$(jq -r '.results[] | select(.id=="eq-mismatch") | .status' <<<"$out")" = "CRIT" ] \
  && note "drift eq mismatch is CRIT" || bad "drift eq mismatch should be CRIT"
[ "$(jq -r '.results[] | select(.id=="le-ok") | .status' <<<"$out")" = "OK" ] \
  && note "drift le within is OK" || bad "drift le within should be OK"
[ "$(jq -r '.results[] | select(.id=="le-tripped") | .status' <<<"$out")" = "CRIT" ] \
  && note "drift le exceeded is CRIT" || bad "drift le exceeded should be CRIT"

# --- §7 error contract: can't-run is CRIT, never OK/skip ---
cat > "$tmp/err.json" <<'EOF'
{"schema": "suxos-invariants/v1", "checks": [
  {"id": "query-fails", "kind": "ttl", "description": "d", "bound": 5, "live": "echo boom >&2; exit 1"},
  {"id": "non-numeric", "kind": "ttl", "description": "d", "bound": 5, "live": "echo not-a-number"},
  {"id": "hangs",       "kind": "ttl", "description": "d", "bound": 5, "live": "sleep 30; echo 1"}
]}
EOF
out=$(python3 invariants/runner.py --manifest "$tmp/err.json" --timeout 2) \
  || bad "runner should still exit 0 when checks themselves fail"
for id in query-fails non-numeric hangs; do
  [ "$(jq -r --arg i "$id" '.results[] | select(.id==$i) | .status' <<<"$out")" = "CRIT" ] \
    && note "$id reported CRIT" || bad "$id should be CRIT (§7: can't-run is a signal)"
done
grep -q "boom" <<<"$(jq -r '.results[] | select(.id=="query-fails") | .message' <<<"$out")" \
  && note "query failure carries stderr text" || bad "CRIT message should carry the stderr text"

# --- unusable manifest exits nonzero (loud step failure) ---
echo '{"schema": "wrong/v9", "checks": []}' > "$tmp/bad-schema.json"
if python3 invariants/runner.py --manifest "$tmp/bad-schema.json" >/dev/null 2>&1; then
  bad "wrong schema should exit nonzero"
else
  note "wrong schema exits nonzero"
fi
echo '{"schema": "suxos-invariants/v1", "checks": [{"id": "x", "kind": "bogus"}]}' > "$tmp/bad-kind.json"
if python3 invariants/runner.py --manifest "$tmp/bad-kind.json" >/dev/null 2>&1; then
  bad "unknown kind should exit nonzero"
else
  note "unknown kind exits nonzero"
fi

[ "$fail" -eq 0 ] && echo "PASS: test-invariants-runner"
exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-invariants-runner.sh`
Expected: FAIL — `python3: can't open file '.../invariants/runner.py'` (nonzero exit).

- [ ] **Step 3: Write the runner (drift/ttl only; effect stub in Task 2)**

```python
#!/usr/bin/env python3
"""Invariant registry runner (docs/design/2026-07-23-pipeline-invariant-registry-design.md).

Read-only: evaluates every check and prints one normalized JSON result set to
stdout. All mutation (needs-human alert upsert, auto-remediation) lives in
fabric-health.yml steps that consume this output — keeping the runner
side-effect-free is what makes it testable with nothing but fixture manifests.

Input is the manifest as JSON (`yq -o=json invariants/manifest.yml`): the
manifest stays YAML for humans, but the runner takes JSON so it needs no YAML
dependency (stdlib only; yq is already a hard dependency of scripts/test-*.sh).

Error contract (design §7): a check that cannot run (query failure, timeout,
non-numeric output, crash) is reported as CRIT with the error text — never a
silent skip. Only an unusable manifest exits nonzero, which fails the workflow
step itself loudly.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

RESULT_SCHEMA = "suxos-invariants-result/v1"
MANIFEST_SCHEMA = "suxos-invariants/v1"


def run_shell(script, timeout):
    # -euo pipefail: a failing gh/jq anywhere in the snippet fails the whole
    # query, which we report as CRIT below — the manifest-level version of the
    # collection-integrity contract (#305): never a fabricated healthy value.
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        capture_output=True, text=True, timeout=timeout,
    )


def result(check_id, kind, severity, status, message, remediate=None):
    return {"id": check_id, "kind": kind, "severity": severity,
            "status": status, "message": message[:500], "remediate": remediate}


def crit_unrunnable(check, message):
    return result(check["id"], check["kind"], check.get("severity", "crit"),
                  "CRIT", message, check.get("remediate"))


def eval_data_check(check, timeout):
    kind = check["kind"]
    severity = check.get("severity", "crit")
    tripped = severity.upper()
    remediate = check.get("remediate")
    try:
        live = run_shell(check["live"], timeout)
    except subprocess.TimeoutExpired:
        return crit_unrunnable(check, f"live query timed out after {timeout}s")
    if live.returncode != 0:
        return crit_unrunnable(
            check, f"live query failed (exit {live.returncode}): {live.stderr.strip()}")
    live_val = live.stdout.strip()

    if kind == "ttl":
        try:
            n, bound = float(live_val), float(check["bound"])
        except (ValueError, KeyError) as exc:
            return crit_unrunnable(check, f"ttl misconfigured or non-numeric live output: {exc!r} (got {live_val!r})")
        if n > bound:
            return result(check["id"], kind, severity, tripped,
                          f"live {n:g} exceeds bound {bound:g}", remediate)
        return result(check["id"], kind, severity, "OK",
                      f"live {n:g} within bound {bound:g}", remediate)

    # kind == "drift"
    try:
        declared = run_shell(check["declared"], timeout)
    except subprocess.TimeoutExpired:
        return crit_unrunnable(check, f"declared query timed out after {timeout}s")
    except KeyError:
        return crit_unrunnable(check, "drift check missing 'declared'")
    if declared.returncode != 0:
        return crit_unrunnable(
            check, f"declared query failed (exit {declared.returncode}): {declared.stderr.strip()}")
    declared_val = declared.stdout.strip()
    compare = check.get("compare", "eq")
    if compare == "le":
        try:
            ok = float(live_val) <= float(declared_val)
        except ValueError:
            return crit_unrunnable(
                check, f"compare=le needs numeric outputs, got live={live_val!r} declared={declared_val!r}")
    else:
        ok = live_val == declared_val
    if ok:
        return result(check["id"], kind, severity, "OK",
                      f"live matches declared ({compare}: {live_val!r})", remediate)
    return result(check["id"], kind, severity, tripped,
                  f"drift: live {live_val!r} vs declared {declared_val!r} ({compare})", remediate)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", required=True,
                    help="manifest as JSON (yq -o=json invariants/manifest.yml)")
    ap.add_argument("--effect-dir", default=None,
                    help="directory of effect-check *.py scripts (optional)")
    ap.add_argument("--timeout", type=int, default=120,
                    help="per-query / per-effect-check timeout in seconds")
    args = ap.parse_args()

    try:
        manifest = json.loads(Path(args.manifest).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"unusable manifest: {exc}", file=sys.stderr)
        return 1
    if manifest.get("schema") != MANIFEST_SCHEMA:
        print(f"unusable manifest: schema must be {MANIFEST_SCHEMA!r}", file=sys.stderr)
        return 1

    results = []
    for check in manifest.get("checks", []):
        if not isinstance(check, dict) or "id" not in check \
                or check.get("kind") not in ("ttl", "drift"):
            print(f"unusable manifest: bad check entry {check!r}", file=sys.stderr)
            return 1
        results.append(eval_data_check(check, args.timeout))

    # Effect-check discovery is added in a follow-up commit (see the plan's
    # Task 2); --effect-dir is accepted now so the CLI is stable.

    json.dump({"schema": RESULT_SCHEMA, "results": results}, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-invariants-runner.sh`
Expected: every `ok:` line prints, final line `PASS: test-invariants-runner`, exit 0.

- [ ] **Step 5: Wire into self-check.yml**

In `.github/workflows/self-check.yml`, append to the `invariants` job's steps (after the last existing `Assert ...` step, keeping the one-explicit-step-per-script convention):

```yaml
      - name: Assert invariants runner drift/ttl semantics
        run: bash scripts/test-invariants-runner.sh
        shell: bash
```

- [ ] **Step 6: Verify actionlint passes locally (if installed) and commit**

```bash
git add invariants/runner.py scripts/test-invariants-runner.sh .github/workflows/self-check.yml
git commit -m "feat(invariants): registry runner core — drift/ttl evaluation"
```

---

### Task 2: Effect-check discovery and contract

**Files:**
- Modify: `invariants/runner.py`
- Create: `scripts/test-invariants-effect-contract.sh`
- Modify: `.github/workflows/self-check.yml` (add one step)

**Interfaces:**
- Consumes: Task 1's runner CLI and `result()` shape.
- Produces: `--effect-dir DIR` now runs every `DIR/*.py` (sorted) via `sys.executable`; each yields a result with `id` = filename stem, `kind` = `"effect"`, `severity` = `"crit"`, `status` from exit code (0/1/2 → OK/WARN/CRIT; anything else, crash, or timeout → CRIT), `message` = first stdout line (or stderr on crash), `remediate` = `null`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Tests the effect-check contract (design §4.2): invariants/runner.py discovers
# every *.py in --effect-dir, exit 0/1/2 map to OK/WARN/CRIT with the first
# stdout line as message, and — §7 — a crash (other exit code) or timeout is
# CRIT, never a skip. Fixture scripts are generated into a tmpdir; offline.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/effect"
echo '{"schema": "suxos-invariants/v1", "checks": []}' > "$tmp/empty.json"

cat > "$tmp/effect/a_ok.py"    <<'EOF'
print("all good"); raise SystemExit(0)
EOF
cat > "$tmp/effect/b_warn.py"  <<'EOF'
print("getting warm"); raise SystemExit(1)
EOF
cat > "$tmp/effect/c_crit.py"  <<'EOF'
print("on fire"); raise SystemExit(2)
EOF
cat > "$tmp/effect/d_crash.py" <<'EOF'
import sys; print("boom-detail", file=sys.stderr); raise SystemExit(3)
EOF
cat > "$tmp/effect/e_hang.py"  <<'EOF'
import time; time.sleep(30)
EOF

out=$(python3 invariants/runner.py --manifest "$tmp/empty.json" \
  --effect-dir "$tmp/effect" --timeout 2) || bad "runner exited nonzero"

expect() {  # id status
  [ "$(jq -r --arg i "$1" '.results[] | select(.id==$i) | .status' <<<"$out")" = "$2" ] \
    && note "$1 -> $2" || bad "$1 should be $2"
}
expect a_ok OK
expect b_warn WARN
expect c_crit CRIT
expect d_crash CRIT
expect e_hang CRIT

[ "$(jq -r '.results[] | select(.id=="a_ok") | .message' <<<"$out")" = "all good" ] \
  && note "message is first stdout line" || bad "message should be the first stdout line"
[ "$(jq -r '.results[] | select(.id=="a_ok") | .kind' <<<"$out")" = "effect" ] \
  && note "kind is effect" || bad "kind should be effect"
grep -q "boom-detail" <<<"$(jq -r '.results[] | select(.id=="d_crash") | .message' <<<"$out")" \
  && note "crash carries stderr detail" || bad "crash CRIT should carry stderr detail"
grep -qi "timed out" <<<"$(jq -r '.results[] | select(.id=="e_hang") | .message' <<<"$out")" \
  && note "timeout says timed out" || bad "timeout CRIT should say timed out"

# Discovery order is sorted by filename (deterministic output for dedup/diffing).
[ "$(jq -r '[.results[].id] | join(",")' <<<"$out")" = "a_ok,b_warn,c_crit,d_crash,e_hang" ] \
  && note "discovery sorted by filename" || bad "effect discovery should be filename-sorted"

[ "$fail" -eq 0 ] && echo "PASS: test-invariants-effect-contract"
exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-invariants-effect-contract.sh`
Expected: FAIL — the five `expect` lines report missing results (runner ignores `--effect-dir`).

- [ ] **Step 3: Implement effect discovery in runner.py**

Add this function after `eval_data_check` and replace the Task-1 placeholder comment in `main()`:

```python
def eval_effect(path, timeout):
    check_id = path.stem
    try:
        proc = subprocess.run([sys.executable, str(path)],
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return result(check_id, "effect", "crit", "CRIT",
                      f"effect check timed out after {timeout}s")
    lines = proc.stdout.strip().splitlines()
    message = lines[0] if lines else "(no output)"
    status = {0: "OK", 1: "WARN", 2: "CRIT"}.get(proc.returncode)
    if status is None:
        detail = proc.stderr.strip() or message
        return result(check_id, "effect", "crit", "CRIT",
                      f"crashed (exit {proc.returncode}): {detail}")
    return result(check_id, "effect", "crit", status, message)
```

In `main()`, replace:

```python
    # Effect-check discovery is added in a follow-up commit (see the plan's
    # Task 2); --effect-dir is accepted now so the CLI is stable.
```

with:

```python
    if args.effect_dir:
        for path in sorted(Path(args.effect_dir).glob("*.py")):
            results.append(eval_effect(path, args.timeout))
```

- [ ] **Step 4: Run both tests to verify they pass**

Run: `bash scripts/test-invariants-effect-contract.sh && bash scripts/test-invariants-runner.sh`
Expected: both print `PASS: ...`, exit 0.

- [ ] **Step 5: Wire into self-check.yml and commit**

Append to the `invariants` job:

```yaml
      - name: Assert invariants effect-check contract
        run: bash scripts/test-invariants-effect-contract.sh
        shell: bash
```

```bash
git add invariants/runner.py scripts/test-invariants-effect-contract.sh .github/workflows/self-check.yml
git commit -m "feat(invariants): effect-check discovery with exit-code contract"
```

---

### Task 3: Manifest lint + the real v1 manifest

**Files:**
- Create: `scripts/check-invariants-manifest.sh`
- Create: `invariants/manifest.yml`
- Create: `scripts/test-invariants-manifest.sh`
- Modify: `.github/workflows/self-check.yml` (add two steps)

**Interfaces:**
- Consumes: Task 1's runner CLI (for the real-manifest smoke).
- Produces: `bash scripts/check-invariants-manifest.sh [path]` — exit 0 with `ok:` line when the manifest passes v1 lint, exit 1 with `FAIL:` lines naming each offending check id otherwise. And `invariants/manifest.yml` itself: the three v1 data entries (`issue-build-retry-bound`, `stale-override-sweep`, `fabric-health-cadence`) whose ids Tasks 5–6 reference.

- [ ] **Step 1: Write the failing lint test**

```bash
#!/usr/bin/env bash
# Tests scripts/check-invariants-manifest.sh (the lint-enforceable slice of the
# design's §4.5 contribution rule) against fixture manifests each violating one
# rule, then smokes the REAL invariants/manifest.yml end-to-end through the real
# runner with a fake gh (empty lists) — asserting every real check reads OK on a
# healthy, empty fabric. Offline; gh is shimmed.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

expect_reject() {  # $1 = label, $2 = fixture path, $3 = text the FAIL must mention
  out=$(bash scripts/check-invariants-manifest.sh "$2" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q "$3" <<<"$out"; then
    note "rejects $1"
  else
    bad "should reject $1 mentioning '$3' (rc=$rc): $out"
  fi
}

cat > "$tmp/dup-id.yml" <<'EOF'
schema: suxos-invariants/v1
checks:
  - {id: same, kind: ttl, description: d, bound: 1, live: "echo 0"}
  - {id: same, kind: ttl, description: d, bound: 1, live: "echo 0"}
EOF
expect_reject "duplicate ids" "$tmp/dup-id.yml" "duplicate"

cat > "$tmp/bad-kind.yml" <<'EOF'
schema: suxos-invariants/v1
checks:
  - {id: x, kind: sideways, description: d, live: "echo 0"}
EOF
expect_reject "unknown kind" "$tmp/bad-kind.yml" "kind"

cat > "$tmp/ttl-no-bound.yml" <<'EOF'
schema: suxos-invariants/v1
checks:
  - {id: x, kind: ttl, description: d, live: "echo 0"}
EOF
expect_reject "ttl without bound" "$tmp/ttl-no-bound.yml" "bound"

cat > "$tmp/drift-no-declared.yml" <<'EOF'
schema: suxos-invariants/v1
checks:
  - {id: x, kind: drift, description: d, live: "echo 0"}
EOF
expect_reject "drift without declared" "$tmp/drift-no-declared.yml" "declared"

cat > "$tmp/remediate-on-drift.yml" <<'EOF'
schema: suxos-invariants/v1
checks:
  - id: x
    kind: drift
    description: d
    declared: "echo a"
    live: "echo a"
    remediate: {action: disable-workflow, repo: SuxOS/.github, workflow: y.yml}
EOF
expect_reject "remediate on drift" "$tmp/remediate-on-drift.yml" "ttl-only"

cat > "$tmp/remediate-cross-repo.yml" <<'EOF'
schema: suxos-invariants/v1
checks:
  - id: x
    kind: ttl
    description: d
    bound: 1
    live: "echo 0"
    remediate: {action: disable-workflow, repo: SuxOS/sux, workflow: y.yml}
EOF
expect_reject "cross-repo remediate" "$tmp/remediate-cross-repo.yml" "SuxOS/.github"

cat > "$tmp/wrong-schema.yml" <<'EOF'
schema: something/v0
checks: []
EOF
expect_reject "wrong schema" "$tmp/wrong-schema.yml" "schema"

# --- the real manifest passes lint ---
if bash scripts/check-invariants-manifest.sh >/dev/null; then
  note "real manifest passes lint"
else
  bad "real invariants/manifest.yml fails its own lint"
fi

# --- real-manifest smoke through the real runner, fake gh, healthy-empty fabric ---
cat > "$tmp/gh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
chmod +x "$tmp/gh"
yq -o=json invariants/manifest.yml > "$tmp/manifest.json"
out=$(PATH="$tmp:$PATH" python3 invariants/runner.py --manifest "$tmp/manifest.json" --timeout 30) \
  || bad "runner exited nonzero on the real manifest"
not_ok=$(jq -r '.results[] | select(.status != "OK") | "\(.id)=\(.status): \(.message)"' <<<"$out")
if [ -z "$not_ok" ]; then
  note "all real data checks OK on an empty fabric"
else
  bad "real checks not OK on empty fabric: $not_ok"
fi

[ "$fail" -eq 0 ] && echo "PASS: test-invariants-manifest"
exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-invariants-manifest.sh`
Expected: FAIL — `check-invariants-manifest.sh: No such file or directory`.

- [ ] **Step 3: Write the lint**

```bash
#!/usr/bin/env bash
# Lint invariants/manifest.yml against the suxos-invariants/v1 schema — the
# enforceable slice of the design's §4.5 contribution rule (docs/design/
# 2026-07-23-pipeline-invariant-registry-design.md). Runs in self-check.yml so a
# malformed entry is rejected at PR time, not discovered as a CRIT (or worse, a
# silently-skipped check) on the next fabric-health tick.
#
# v1 remediation constraints enforced here (design §5): remediate is ttl-only,
# action must be disable-workflow, and repo must be SuxOS/.github — the workflow
# GITHUB_TOKEN is repo-scoped, so a cross-repo remediate would 403 at runtime.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
MANIFEST="${1:-invariants/manifest.yml}"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

json=$(yq -o=json "$MANIFEST" 2>&1) || { bad "manifest is not parseable YAML: $json"; exit 1; }

[ "$(jq -r '.schema // ""' <<<"$json")" = "suxos-invariants/v1" ] \
  || bad "schema must be suxos-invariants/v1"

dupes=$(jq -r '[.checks[]?.id] | group_by(.) | map(select(length > 1) | .[0]) | join(",")' <<<"$json")
[ -z "$dupes" ] || bad "duplicate ids: $dupes"
badids=$(jq -r '.checks[]?.id // "" | select(test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)' <<<"$json")
[ -z "$badids" ] || bad "ids must be kebab-case: $badids"

while IFS= read -r entry; do
  id=$(jq -r '.id // "(missing id)"' <<<"$entry")
  kind=$(jq -r '.kind // ""' <<<"$entry")
  case "$kind" in ttl|drift) ;; *) bad "$id: kind must be ttl|drift (got '$kind')" ;; esac
  sev=$(jq -r '.severity // "crit"' <<<"$entry")
  case "$sev" in warn|crit) ;; *) bad "$id: severity must be warn|crit (got '$sev')" ;; esac
  [ "$(jq -r '.description // "" | length' <<<"$entry")" -gt 0 ] || bad "$id: description required"
  [ "$(jq -r '.live // "" | length' <<<"$entry")" -gt 0 ] || bad "$id: live query required"
  if [ "$kind" = "ttl" ]; then
    jq -e '.bound | numbers' <<<"$entry" >/dev/null 2>&1 || bad "$id: ttl needs a numeric bound"
  fi
  if [ "$kind" = "drift" ]; then
    [ "$(jq -r '.declared // "" | length' <<<"$entry")" -gt 0 ] || bad "$id: drift needs declared"
    case "$(jq -r '.compare // "eq"' <<<"$entry")" in eq|le) ;; *) bad "$id: compare must be eq|le" ;; esac
  fi
  if jq -e '.remediate' <<<"$entry" >/dev/null 2>&1; then
    [ "$kind" = "ttl" ] || bad "$id: remediate is ttl-only (design §5)"
    [ "$(jq -r '.remediate.action // ""' <<<"$entry")" = "disable-workflow" ] \
      || bad "$id: v1 remediate action must be disable-workflow"
    [ "$(jq -r '.remediate.repo // ""' <<<"$entry")" = "SuxOS/.github" ] \
      || bad "$id: v1 remediate.repo must be SuxOS/.github (GITHUB_TOKEN is repo-scoped)"
    [ "$(jq -r '.remediate.workflow // "" | length' <<<"$entry")" -gt 0 ] \
      || bad "$id: remediate.workflow required"
  fi
done < <(jq -c '.checks[]?' <<<"$json")

[ "$fail" -eq 0 ] && echo "ok: $MANIFEST passes suxos-invariants/v1 lint"
exit "$fail"
```

- [ ] **Step 4: Write the real manifest**

```yaml
# Invariant registry manifest (docs/design/2026-07-23-pipeline-invariant-registry-design.md §4).
# Declarative drift/ttl entries only — effect checks live in invariants/effect/*.py.
#
# Every entry: id (unique kebab-case), kind (ttl|drift), description, optional
# severity (warn|crit, default crit), plus the kind's own fields. `live`/`declared`
# are bash snippets run under `bash -euo pipefail` with a per-check timeout: any
# query failure fails the snippet, which the runner reports as CRIT — the
# manifest-level version of fabric-health's collection-integrity contract (#305),
# never a fabricated healthy value. cwd is this repo's checkout root.
#
# `remediate` is opt-in and ttl-only; v1 action is `disable-workflow` against THIS
# repo only (lint-enforced by scripts/check-invariants-manifest.sh — the workflow
# GITHUB_TOKEN cannot disable a workflow cross-repo).
#
# Per-instance permanent escape hatch (design §4.1): a `live` query must itself
# exclude instances carrying that domain's permanent marker (the `permanent`
# label below), keeping the runner generic — permanence is a property of the
# specific override, not of the check.
schema: suxos-invariants/v1
checks:
  - id: issue-build-retry-bound
    kind: ttl
    severity: crit
    description: >-
      #701 signature: consecutive most-recent runs of self-issue-build.yml all
      completed as cancelled (the 30-min job-timeout cancel loop). A healthy
      batch resolves (success or explicit give-up) well within 6 tries; 28 in a
      row is what burned ~868 runner-minutes on 2026-07-22.
    bound: 6
    live: |
      gh run list --repo "SuxOS/.github" --workflow self-issue-build.yml \
        --limit 30 --json conclusion,status \
      | jq '[ .[] | select(.status == "completed") | .conclusion ]
            | reduce .[] as $c ({n: 0, stop: false};
                if .stop then .
                elif $c == "cancelled" then {n: (.n + 1), stop: false}
                else {n: .n, stop: true} end)
            | .n'
    remediate:
      action: disable-workflow
      repo: SuxOS/.github
      workflow: self-issue-build.yml

  - id: stale-override-sweep
    kind: ttl
    severity: crit
    description: >-
      Never-self-heals class (design §1.2): open hold / throttle-manual override
      issues older than 14 days that do not carry the `permanent` label, summed
      across every managed repo. The healthy state is 0 — an override either
      expires (gets closed) or is explicitly marked permanent.
    bound: 0
    live: |
      cutoff=$(date -u -d "-14 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)
      total=0
      while read -r repo; do
        for label in hold throttle-manual; do
          n=$(gh issue list --repo "SuxOS/${repo}" --state open --label "$label" \
            --limit 200 --json updatedAt,labels \
            | jq --arg c "$cutoff" \
              '[ .[] | select(.updatedAt < $c)
                 | select(([.labels[].name] | index("permanent")) | not) ] | length')
          total=$((total + n))
        done
      done < <(jq -r '(.repos + [".github"])[]' .github/managed-repos.json)
      echo "$total"

  - id: fabric-health-cadence
    kind: drift
    severity: crit
    description: >-
      Registry self-watch (design §7): declared "self-fabric-health runs every
      15 min" vs live minutes since its previous successful run. Catches a cron
      gap (disabled window, repeated failures) on the first run after it —
      no second watcher to build, just another manifest entry.
    compare: le
    declared: |
      echo 60
    live: |
      updated=$(gh run list --repo "SuxOS/.github" --workflow self-fabric-health.yml \
        --status success --limit 1 --json updatedAt | jq -r '.[0].updatedAt // empty')
      if [ -z "$updated" ]; then echo 0; exit 0; fi
      then_epoch=$(date -u -d "$updated" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated" +%s)
      echo $(( ( $(date -u +%s) - then_epoch ) / 60 ))
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash scripts/test-invariants-manifest.sh`
Expected: all `ok:` lines including `real manifest passes lint` and `all real data checks OK on an empty fabric`; `PASS: test-invariants-manifest`.

- [ ] **Step 6: Wire into self-check.yml and commit**

Append to the `invariants` job — the lint runs directly (gating the real manifest on every PR) and the test script guards the lint's own logic:

```yaml
      - name: Lint invariants manifest (suxos-invariants/v1)
        run: bash scripts/check-invariants-manifest.sh
        shell: bash

      - name: Assert invariants manifest lint + real-manifest smoke
        run: bash scripts/test-invariants-manifest.sh
        shell: bash
```

```bash
git add invariants/manifest.yml scripts/check-invariants-manifest.sh scripts/test-invariants-manifest.sh .github/workflows/self-check.yml
git commit -m "feat(invariants): v1 manifest (retry-bound, stale-override, cadence) + schema lint"
```

---

### Task 4: The two effect checks

**Files:**
- Create: `invariants/effect/cost_effectiveness.py`
- Create: `invariants/effect/grafana_push_verify.py`
- Create: `scripts/test-invariants-effect-checks.sh`
- Modify: `.github/workflows/self-check.yml` (add one step)

**Interfaces:**
- Consumes: the effect contract from Task 2 (exit 0/1/2, first stdout line = message).
- Produces: `cost_effectiveness.py` reading env `REPOS` (space-separated repo names), `ORG` (default `SuxOS`), `COST_WINDOW_HOURS` (default 24), `COST_WARN_MIN` (default 60), `COST_CRIT_MIN` (default 180), calling `gh` via subprocess. `grafana_push_verify.py` reading env `GRAFANA_PROM_QUERY_URL`/`GRAFANA_PROM_QUERY_USER`/`GRAFANA_PROM_QUERY_TOKEN`, calling `curl` via subprocess (PATH-shimmable, matching the repo's fake-binary test pattern). Task 5 wires these env vars in the workflow step.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Tests the two real effect checks (design §3) with fake gh/curl PATH shims:
#   cost_effectiveness.py — CRIT on runner-minutes with zero output (#701 broad
#     signature), OK when output exists, and exit 2 on a failed collection (§7:
#     "couldn't measure" is never OK).
#   grafana_push_verify.py — inert exit 0 when secrets unset (the repo's
#     dormant-until-secrets contract), CRIT when the range-vector query returns
#     no series (#694 signature), OK when samples exist.
# Offline; no real gh/curl calls.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Fake gh for cost_effectiveness: 6h-old still-running run (=> ~360 wall-clock
# minutes, past CRIT_MIN=180), merged/closed counts from env knobs.
start=$(date -u -d "-6 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-6H +%Y-%m-%dT%H:%M:%SZ)
cat > "$tmp/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/gh-calls.log"
case "\$1 \$2" in
  "run list")   echo '[{"startedAt": "$start", "updatedAt": "$start", "status": "in_progress"}]' ;;
  "pr list")    echo "\${FAKE_MERGED:-[]}" ;;
  "issue list") echo "\${FAKE_CLOSED:-[]}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"

run_cost() { PATH="$tmp:$PATH" REPOS="sux" python3 invariants/effect/cost_effectiveness.py; }

out=$(FAKE_MERGED='[]' FAKE_CLOSED='[]' run_cost); rc=$?
[ "$rc" -eq 2 ] && note "spend w/o output is CRIT (exit 2)" \
  || bad "expected exit 2 for spend w/o output, got $rc: $out"
grep -q "zero output" <<<"$out" && note "CRIT message names the signature" \
  || bad "message should mention zero output: $out"

out=$(FAKE_MERGED='[{"number":1}]' FAKE_CLOSED='[]' run_cost); rc=$?
[ "$rc" -eq 0 ] && note "spend WITH output is OK (exit 0)" \
  || bad "expected exit 0 when a PR merged, got $rc: $out"

out=$(PATH="$tmp:$PATH" REPOS="" python3 invariants/effect/cost_effectiveness.py); rc=$?
[ "$rc" -eq 2 ] && note "empty REPOS is CRIT (misconfigured, not silent)" \
  || bad "expected exit 2 on empty REPOS, got $rc"

mkdir -p "$tmp/broken-bin"
cat > "$tmp/broken-bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/broken-bin/gh"
out=$(PATH="$tmp/broken-bin:$PATH" REPOS="sux" python3 invariants/effect/cost_effectiveness.py); rc=$?
[ "$rc" -eq 2 ] && note "gh failure is CRIT (collection failed)" \
  || bad "expected exit 2 on gh failure, got $rc: $out"

# --- grafana_push_verify ---
out=$(python3 invariants/effect/grafana_push_verify.py); rc=$?
[ "$rc" -eq 0 ] && grep -qi "inert" <<<"$out" && note "secrets unset -> inert exit 0" \
  || bad "expected inert exit 0 with secrets unset, got $rc: $out"

mkdir -p "$tmp/curl-empty" "$tmp/curl-ok"
cat > "$tmp/curl-empty/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"status": "success", "data": {"resultType": "vector", "result": []}}'
EOF
cat > "$tmp/curl-ok/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"status": "success", "data": {"resultType": "vector", "result": [{"metric": {}, "value": [1753228800, "3"]}]}}'
EOF
chmod +x "$tmp/curl-empty/curl" "$tmp/curl-ok/curl"

verify_env=(GRAFANA_PROM_QUERY_URL="https://prom.example/api/v1/query" \
  GRAFANA_PROM_QUERY_USER="u" GRAFANA_PROM_QUERY_TOKEN="t")
out=$(env "${verify_env[@]}" PATH="$tmp/curl-empty:$PATH" python3 invariants/effect/grafana_push_verify.py); rc=$?
[ "$rc" -eq 2 ] && grep -qi "dark" <<<"$out" && note "empty result -> CRIT push-dark" \
  || bad "expected CRIT on empty query result, got $rc: $out"
out=$(env "${verify_env[@]}" PATH="$tmp/curl-ok:$PATH" python3 invariants/effect/grafana_push_verify.py); rc=$?
[ "$rc" -eq 0 ] && note "samples present -> OK" \
  || bad "expected OK when samples exist, got $rc: $out"

[ "$fail" -eq 0 ] && echo "PASS: test-invariants-effect-checks"
exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-invariants-effect-checks.sh`
Expected: FAIL — `can't open file '.../invariants/effect/cost_effectiveness.py'`.

- [ ] **Step 3: Write cost_effectiveness.py**

```python
#!/usr/bin/env python3
"""Effect invariant (design §3): spend without output — the broader #701
signature. CRIT when a managed repo burned real runner-minutes over the
trailing window while landing zero output (no merged PRs, no closed issues).

Minutes math mirrors budget-governor.yml exactly: per run,
(completed ? updatedAt : now) - startedAt, so a wedged in-progress run counts
while it is still burning. Wall-clock runner-minutes are a proxy for spend,
not a bill (docs/design/budget-and-cadence.md).

Contract (design §4.2): exit 0/1/2 = OK/WARN/CRIT, first stdout line is the
message. A failed collection exits 2 (design §7: "couldn't measure" is never
OK) — the same reason fabric-health's collectors emit suxos_collection_ok=0
instead of a healthy-looking zero (#305).
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

WINDOW_HOURS = int(os.environ.get("COST_WINDOW_HOURS", "24"))
WARN_MIN = float(os.environ.get("COST_WARN_MIN", "60"))
CRIT_MIN = float(os.environ.get("COST_CRIT_MIN", "180"))
ORG = os.environ.get("ORG", "SuxOS")


def gh_json(args):
    proc = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:2])} failed: {proc.stderr.strip()[:200]}")
    return json.loads(proc.stdout)


def parse_iso(stamp):
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def main():
    repos = os.environ.get("REPOS", "").split()
    if not repos:
        print("misconfigured: REPOS env is empty")
        return 2
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(hours=WINDOW_HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    worst_warn = None
    try:
        for repo in repos:
            slug = f"{ORG}/{repo}"
            runs = gh_json(["run", "list", "--repo", slug, "--limit", "500",
                            "--created", f">={cutoff}",
                            "--json", "startedAt,updatedAt,status"])
            minutes = 0.0
            for run in runs:
                if not run.get("startedAt"):
                    continue
                start = parse_iso(run["startedAt"])
                end = parse_iso(run["updatedAt"]) if run.get("status") == "completed" else now
                minutes += max(0.0, (end - start).total_seconds() / 60)
            if minutes < WARN_MIN:
                continue
            merged = len(gh_json(["pr", "list", "--repo", slug, "--state", "merged",
                                  "--limit", "200", "--search", f"merged:>={cutoff}",
                                  "--json", "number"]))
            closed = len(gh_json(["issue", "list", "--repo", slug, "--state", "closed",
                                  "--limit", "200", "--search", f"closed:>={cutoff}",
                                  "--json", "number"]))
            if merged + closed > 0:
                continue
            message = (f"{slug}: {minutes:.0f} runner-min in {WINDOW_HOURS}h with zero output "
                       f"(0 merged PRs, 0 closed issues) — livelock signature")
            if minutes >= CRIT_MIN:
                print(message)
                return 2
            worst_warn = message
    except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError, ValueError) as exc:
        print(f"collection failed: {exc}")
        return 2
    if worst_warn:
        print(worst_warn)
        return 1
    print(f"all repos: spend correlates with output over trailing {WINDOW_HOURS}h")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Write grafana_push_verify.py**

```python
#!/usr/bin/env python3
"""Effect invariant (#694, design §3): fabric-health's Grafana push step can
report HTTP 2xx while the dashboard is dark. Round-trip verify: query the
Prometheus HTTP API for count_over_time(suxos_collector_ok[45m]) — a range
vector spanning three push ticks, not an instant query (an instant query's 5m
lookback would always miss the previous 15-min-cadence push).

Dormant until GRAFANA_PROM_QUERY_URL/USER/TOKEN exist (same contract as the
push itself) — exits 0 with an explicit "inert" message, never silently.
Uses curl (not urllib) so tests can shim it via PATH, the same fake-binary
pattern every scripts/test-*.sh here uses for gh.

Contract (design §4.2): exit 0/1/2 = OK/WARN/CRIT, first stdout line is the
message. Query failure exits 2 — "couldn't verify" is never OK (design §7).
"""
import json
import os
import subprocess
import sys

QUERY = "count_over_time(suxos_collector_ok[45m])"


def main():
    url = os.environ.get("GRAFANA_PROM_QUERY_URL", "")
    user = os.environ.get("GRAFANA_PROM_QUERY_USER", "")
    token = os.environ.get("GRAFANA_PROM_QUERY_TOKEN", "")
    if not (url and user and token):
        print("inert: GRAFANA_PROM_QUERY_* secrets unset (push verification dormant)")
        return 0
    try:
        proc = subprocess.run(
            ["curl", "-sS", "--fail-with-body", "--max-time", "30",
             "-u", f"{user}:{token}", "--data-urlencode", f"query={QUERY}", url],
            capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        print("query timed out — cannot verify the push landed")
        return 2
    if proc.returncode != 0:
        print(f"query failed (curl exit {proc.returncode}): {proc.stderr.strip()[:200]}")
        return 2
    try:
        payload = json.loads(proc.stdout)
        series = payload["data"]["result"]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        print(f"unparseable query response: {exc}")
        return 2
    if not series:
        print("suxos_collector_ok has NO samples in the last 45m — push is dark (#694 signature)")
        return 2
    print(f"push verified: suxos_collector_ok sampled within 45m ({len(series)} series)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash scripts/test-invariants-effect-checks.sh`
Expected: all `ok:` lines; `PASS: test-invariants-effect-checks`.

- [ ] **Step 6: Wire into self-check.yml and commit**

Append to the `invariants` job:

```yaml
      - name: Assert cost-effectiveness + grafana-push-verify effect checks
        run: bash scripts/test-invariants-effect-checks.sh
        shell: bash
```

```bash
git add invariants/effect/ scripts/test-invariants-effect-checks.sh .github/workflows/self-check.yml
git commit -m "feat(invariants): cost-effectiveness and grafana-push-verify effect checks"
```

---

### Task 5: Wire the registry into fabric-health.yml (run, remediate, alert, metrics)

**Files:**
- Modify: `.github/workflows/fabric-health.yml` (three new steps after the `fold-edge` step; one line in the Ship step; `permissions.actions` → `write`; `timeout-minutes` 15 → 20)
- Modify: `.github/workflows/self-fabric-health.yml` (spine job `actions: read` → `actions: write`)
- Create: `scripts/test-fabric-health-invariants.sh`
- Modify: `.github/workflows/self-check.yml` (add one step)

**Interfaces:**
- Consumes: runner CLI (Task 1/2), `invariants/manifest.yml` ids (Task 3), effect-check env vars `REPOS`/`GRAFANA_PROM_QUERY_*` (Task 4).
- Produces: workspace files `invariant-results.json` (runner output) and `invariant-metrics.txt` (Influx lines `suxos_invariant_status,id=<id> value=<0|1|2>` and `suxos_invariant_crit_total value=N`); needs-human issues titled exactly `Invariant violation: <id>`; `gh workflow disable` on tripped `remediate` entries. Step ids `invariants`, `invariant-remediate`, `invariant-alerts` (extraction-test anchors).

- [ ] **Step 1: Write the failing extraction test**

This is the design §8 pair of deliberately-failing fixtures: one proving CRIT reaches the needs-human rollup end-to-end, one proving the remediation path fires (against a fixture workflow name, `disposable-test.yml` — never a load-bearing one).

```bash
#!/usr/bin/env bash
# Extraction tests for fabric-health.yml's invariant-registry wiring (design §8:
# the two deliberately-failing fixtures). Extracts the invariant-remediate and
# invariant-alerts steps with yq and drives them against fixture
# invariant-results.json files + a fake gh, asserting:
#   1. a CRIT result CREATES a needs-human "Invariant violation: <id>" issue
#      (the alert path, end-to-end to the gh call),
#   2. a CRIT ttl result with remediate fires `gh workflow disable` with the
#      exact repo/workflow — against a disposable fixture name, never a real one,
#   3. an existing open alert for a still-CRIT id is REFRESHED (edit, not create),
#   4. an open alert whose id is no longer CRIT is comment+closed (recovery),
#   5. an unfetchable open-alert list SKIPS the upsert (warning, no blind create).
# The steps keep ${{ }} out of their run: bodies (env indirection) so the
# extracted bash runs verbatim — same property the collect step has.
#
# Runs from anywhere: resolves paths relative to this script's repo, not the CWD.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
fail=0
note() { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*" >&2; fail=1; }

WF=.github/workflows/fabric-health.yml
remediate_run=$(yq -r '.jobs.spine.steps[] | select(.id == "invariant-remediate") | .run' "$WF")
alerts_run=$(yq -r '.jobs.spine.steps[] | select(.id == "invariant-alerts") | .run' "$WF")
[ -n "$remediate_run" ] || { bad "no invariant-remediate step found"; exit 1; }
[ -n "$alerts_run" ] || { bad "no invariant-alerts step found"; exit 1; }

make_env() {  # $1 = workdir, $2 = open-alerts JSON or the literal string FAIL
  local dir="$1" alerts="$2"
  cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$dir/calls.log"
case "\$1 \$2" in
  "issue list")
    $([ "$alerts" = "FAIL" ] && echo 'exit 1' || printf "cat <<'AL'\n%s\nAL" "$alerts")
    ;;
  "label create") ;;
  "issue create") echo "https://github.com/SuxOS/.github/issues/999" ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$dir/gh"
}

crit_results='{"schema": "suxos-invariants-result/v1", "results": [
  {"id": "issue-build-retry-bound", "kind": "ttl", "severity": "crit", "status": "CRIT",
   "message": "live 9 exceeds bound 6",
   "remediate": {"action": "disable-workflow", "repo": "SuxOS/.github", "workflow": "disposable-test.yml"}},
  {"id": "fabric-health-cadence", "kind": "drift", "severity": "crit", "status": "OK",
   "message": "fine", "remediate": null}
]}'
ok_results='{"schema": "suxos-invariants-result/v1", "results": [
  {"id": "issue-build-retry-bound", "kind": "ttl", "severity": "crit", "status": "OK",
   "message": "live 0 within bound 6", "remediate": null}
]}'

# --- Fixture 1 (deliberately failing): CRIT -> needs-human issue created ---
t1=$(mktemp -d)
make_env "$t1" "[]"
printf '%s' "$crit_results" > "$t1/invariant-results.json"
(cd "$t1" && PATH="$t1:$PATH" GITHUB_REPOSITORY="SuxOS/.github" \
  RUN_URL="https://example.test/run/1" bash -c "$alerts_run")
grep -q "issue create .*Invariant violation: issue-build-retry-bound" "$t1/calls.log" \
  && note "CRIT creates the needs-human alert" || bad "CRIT should create an alert issue"
grep -q "needs-human" "$t1/calls.log" \
  && note "alert carries the needs-human label" || bad "alert should be labeled needs-human"
if grep -q "Invariant violation: fabric-health-cadence" "$t1/calls.log"; then
  bad "an OK id must not get an alert"
else
  note "OK ids get no alert"
fi

# --- Fixture 2 (deliberately failing): CRIT ttl + remediate -> workflow disable ---
t2=$(mktemp -d)
make_env "$t2" "[]"
printf '%s' "$crit_results" > "$t2/invariant-results.json"
(cd "$t2" && PATH="$t2:$PATH" bash -c "$remediate_run")
grep -q "workflow disable disposable-test.yml --repo SuxOS/.github" "$t2/calls.log" \
  && note "remediation disables the named workflow" \
  || bad "remediate should call gh workflow disable disposable-test.yml"

# --- Fixture 3: still-CRIT id with existing alert -> edit, not create ---
t3=$(mktemp -d)
make_env "$t3" '[{"number": 42, "title": "Invariant violation: issue-build-retry-bound"}]'
printf '%s' "$crit_results" > "$t3/invariant-results.json"
(cd "$t3" && PATH="$t3:$PATH" GITHUB_REPOSITORY="SuxOS/.github" \
  RUN_URL="https://example.test/run/1" bash -c "$alerts_run")
grep -q "issue edit 42" "$t3/calls.log" \
  && note "existing alert is refreshed in place" || bad "existing alert should be edited"
if grep -q "issue create" "$t3/calls.log"; then
  bad "existing alert must not be duplicated"
else
  note "no duplicate create"
fi

# --- Fixture 4: recovered id -> comment+close ---
t4=$(mktemp -d)
make_env "$t4" '[{"number": 42, "title": "Invariant violation: issue-build-retry-bound"}]'
printf '%s' "$ok_results" > "$t4/invariant-results.json"
(cd "$t4" && PATH="$t4:$PATH" GITHUB_REPOSITORY="SuxOS/.github" \
  RUN_URL="https://example.test/run/1" bash -c "$alerts_run")
grep -q "issue close 42" "$t4/calls.log" \
  && note "recovered id closes its alert" || bad "recovered alert should be closed"

# --- Fixture 5: unfetchable alert list -> skip, no blind create ---
t5=$(mktemp -d)
make_env "$t5" "FAIL"
printf '%s' "$crit_results" > "$t5/invariant-results.json"
out=$(cd "$t5" && PATH="$t5:$PATH" GITHUB_REPOSITORY="SuxOS/.github" \
  RUN_URL="https://example.test/run/1" bash -c "$alerts_run" 2>&1)
if grep -q "issue create" "$t5/calls.log" 2>/dev/null; then
  bad "must not create alerts when the open-alert list is unfetchable (dup risk)"
else
  note "unfetchable list skips upsert"
fi
grep -q "::warning::" <<<"$out" \
  && note "skip is loud (::warning::)" || bad "skip should emit ::warning::"

rm -rf "$t1" "$t2" "$t3" "$t4" "$t5"
[ "$fail" -eq 0 ] && echo "PASS: test-fabric-health-invariants"
exit "$fail"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-fabric-health-invariants.sh`
Expected: FAIL — `no invariant-remediate step found`.

- [ ] **Step 3: Add the three steps to fabric-health.yml**

Insert immediately after the `Fold edge-check verdicts into fabric-status.json` step (id `fold-edge`) and before the `Evaluate §4 next-arc decision table` step:

```yaml
      # Invariant registry (docs/design/2026-07-23-pipeline-invariant-registry-design.md):
      # drift/ttl entries from invariants/manifest.yml plus effect scripts from
      # invariants/effect/, all evaluated by the read-only runner. The manifest is
      # converted YAML->JSON here with yq so the runner stays stdlib-only. Runs from
      # the .suxos-ci checkout (already present for the trust predicate above) so the
      # manifest's own relative paths (.github/managed-repos.json) resolve. A runner
      # crash or unusable manifest fails THIS step loudly — which the wf_red collector
      # then reports — per the design's §7 "a check that can't run is a signal" rule.
      - name: Run invariant registry
        id: invariants
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ORG: ${{ github.repository_owner }}
          REPOS: ${{ inputs.repos }}
          GRAFANA_PROM_QUERY_URL: ${{ secrets.GRAFANA_PROM_QUERY_URL }}
          GRAFANA_PROM_QUERY_USER: ${{ secrets.GRAFANA_PROM_QUERY_USER }}
          GRAFANA_PROM_QUERY_TOKEN: ${{ secrets.GRAFANA_PROM_QUERY_TOKEN }}
        run: |
          set -euo pipefail
          cd "$GITHUB_WORKSPACE/.suxos-ci"
          yq -o=json invariants/manifest.yml > /tmp/invariants-manifest.json
          python3 invariants/runner.py --manifest /tmp/invariants-manifest.json \
            --effect-dir invariants/effect > "$GITHUB_WORKSPACE/invariant-results.json"
          cd "$GITHUB_WORKSPACE"
          jq -r '.results[] | "\(.status) \(.id) [\(.kind)]: \(.message)"' invariant-results.json
          # Influx lines for the Ship step below (same append pattern as edge-metrics.txt).
          ts="$(date -u +%s)000000000"
          jq -r --arg ts "$ts" '.results[] |
            "suxos_invariant_status,id=\(.id) value=\({"OK": 0, "WARN": 1, "CRIT": 2}[.status]) \($ts)"' \
            invariant-results.json > invariant-metrics.txt
          jq -r --arg ts "$ts" \
            '"suxos_invariant_crit_total value=\([.results[] | select(.status == "CRIT")] | length) \($ts)"' \
            invariant-results.json >> invariant-metrics.txt

      # Bounded auto-remediation (design §5): opt-in per manifest entry, ttl-only,
      # v1 action is exactly `disable-workflow` — the same two commands run by hand
      # during the 2026-07-22 #701 incident. Never silent: the alert step below
      # always files/refreshes the needs-human issue too, and the disabled workflow
      # itself then shows up in suxos_workflow_disabled. Re-enabling is always a
      # manual `gh workflow enable` once the underlying fix lands. Requires
      # actions: write (granted above / in self-fabric-health.yml).
      - name: Auto-remediate tripped ttl invariants
        id: invariant-remediate
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -uo pipefail
          while IFS= read -r entry; do
            repo=$(jq -r '.remediate.repo' <<<"$entry")
            wf=$(jq -r '.remediate.workflow' <<<"$entry")
            invariant=$(jq -r '.id' <<<"$entry")
            if gh workflow disable "$wf" --repo "$repo"; then
              echo "auto-remediated ${invariant}: disabled ${repo}/${wf}"
            else
              echo "::warning::auto-remediation for ${invariant} could not disable ${repo}/${wf} (may already be disabled)"
            fi
          done < <(jq -c '.results[] | select(.status == "CRIT" and .kind == "ttl"
            and .remediate.action == "disable-workflow")' invariant-results.json)

      # Invariant alert upsert (design §4.4): every CRIT gets ONE rolling
      # "Invariant violation: <id>" issue labeled needs-human in THIS repo —
      # dedup by exact title, refreshed in place, comment+closed on recovery, so
      # it rides the existing needs-human rollup (suxos_needs_human_total, the §4
      # spine-green definition) instead of a new alert path. Plain gh in a loop,
      # not the upsert-tracking-issue action: a `uses:` step can't be invoked
      # per-element over a runtime-discovered list (CLAUDE.md), the same reason
      # the epic reconciler above is inline. An unfetchable open-alert list skips
      # the whole upsert with a ::warning:: — acting blind would duplicate issues.
      - name: Upsert invariant needs-human alerts
        id: invariant-alerts
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          set -uo pipefail
          gh label create needs-human --repo "${GITHUB_REPOSITORY}" \
            --color d93f0b --description "Parked for a human decision" 2>/dev/null || true

          if ! open_alerts=$(gh issue list --repo "${GITHUB_REPOSITORY}" --state open \
              --label needs-human --limit 200 --json number,title); then
            echo "::warning::could not list open invariant alerts — skipping upsert this tick"
            exit 0
          fi

          while IFS= read -r entry; do
            id=$(jq -r '.id' <<<"$entry")
            title="Invariant violation: ${id}"
            body=$(printf '%s\n' \
              "Auto-maintained by fabric-health.yml's invariant registry (docs/design/2026-07-23-pipeline-invariant-registry-design.md). Last updated $(date -u '+%Y-%m-%d %H:%M UTC')." \
              "" \
              "**$(jq -r '.kind' <<<"$entry") invariant \`${id}\` is CRIT:** $(jq -r '.message' <<<"$entry")" \
              "$(jq -r 'if .remediate != null then "\n**Auto-remediation:** `" + .remediate.action + "` was applied to `" + .remediate.repo + "/" + .remediate.workflow + "` — re-enable manually (`gh workflow enable`) once the underlying cause is fixed." else "" end' <<<"$entry")" \
              "" \
              "Run: ${RUN_URL}")
            existing=$(jq -r --arg t "$title" \
              '[.[] | select(.title == $t) | .number] | first // empty' <<<"$open_alerts")
            if [ -n "$existing" ]; then
              gh issue edit "$existing" --repo "${GITHUB_REPOSITORY}" --body "$body" \
                || echo "::warning::failed to refresh invariant alert #$existing"
            else
              gh issue create --repo "${GITHUB_REPOSITORY}" --title "$title" \
                --body "$body" --label needs-human \
                || echo "::warning::failed to create invariant alert for ${id}"
            fi
          done < <(jq -c '.results[] | select(.status == "CRIT")' invariant-results.json)

          crit_ids=$(jq -c '[.results[] | select(.status == "CRIT") | .id]' invariant-results.json)
          while IFS= read -r alert; do
            number=$(jq -r '.number' <<<"$alert")
            id=$(jq -r '.title | ltrimstr("Invariant violation: ")' <<<"$alert")
            gh issue close "$number" --repo "${GITHUB_REPOSITORY}" \
              --comment "Invariant \`${id}\` recovered (no longer CRIT as of ${RUN_URL})." \
              || echo "::warning::failed to close recovered invariant alert #$number"
          done < <(jq -c --argjson crit "$crit_ids" \
            '.[] | select(.title | startswith("Invariant violation: "))
               | select((.title | ltrimstr("Invariant violation: ")) as $id
                        | $crit | index($id) | not)' <<<"$open_alerts")
```

- [ ] **Step 4: Append invariant metrics in the Ship step and bump permissions/timeout**

In the `Ship snapshot to Grafana Cloud (Prometheus + Loki)` step, directly under the existing line

```bash
          [ -f edge-metrics.txt ] && cat edge-metrics.txt >> prom-body.txt
```

add:

```bash
          # Invariant registry counts (design §4.4) — same append pattern as edge.
          [ -f invariant-metrics.txt ] && cat invariant-metrics.txt >> prom-body.txt
```

In `fabric-health.yml`'s top-level `permissions:` block change `actions: read` to:

```yaml
  actions: write   # invariant auto-remediation (disable-workflow, design §5); reads still dominate
```

Change the spine job's `timeout-minutes: 15` to `timeout-minutes: 20` (the registry adds up to ~3 min of bounded queries/effect checks in the worst case).

In `self-fabric-health.yml`'s `spine` job `permissions:` block, change `actions: read` to `actions: write` (a reusable workflow's effective permissions are capped by its caller's grant, so both files must change together).

- [ ] **Step 5: Run the extraction test to verify it passes**

Run: `bash scripts/test-fabric-health-invariants.sh`
Expected: all `ok:` lines for the five fixtures; `PASS: test-fabric-health-invariants`.

- [ ] **Step 6: Run actionlint + full local suite, wire into self-check.yml, commit**

Run actionlint if installed locally (`actionlint -color`), plus:

```bash
for t in scripts/test-invariants-*.sh scripts/test-fabric-health-invariants.sh; do bash "$t" || echo "FAILED: $t"; done
```

Expected: every script prints `PASS`. Append to `self-check.yml`'s `invariants` job:

```yaml
      - name: Assert fabric-health invariant wiring (alert + remediation paths)
        run: bash scripts/test-fabric-health-invariants.sh
        shell: bash
```

```bash
git add .github/workflows/fabric-health.yml .github/workflows/self-fabric-health.yml .github/workflows/self-check.yml scripts/test-fabric-health-invariants.sh
git commit -m "feat(invariants): wire registry into fabric-health (metrics, needs-human alerts, bounded remediation)"
```

---

### Task 6: Docs, secrets inventory, and live-fire verification

**Files:**
- Modify: `README.md`
- Modify: `docs/design/2026-07-23-pipeline-invariant-registry-design.md` (status line only)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing downstream — this is the close-out.

- [ ] **Step 1: Update README.md**

Repo CLAUDE.md rule: never add a secret without updating the README's "Required secrets/vars" list. In that section add (marked optional/dormant, like the existing GRAFANA_* entries):

```markdown
- `GRAFANA_PROM_QUERY_URL` / `GRAFANA_PROM_QUERY_USER` / `GRAFANA_PROM_QUERY_TOKEN`
  (optional): Prometheus HTTP query endpoint + read-scoped credentials for the
  invariant registry's push-verification effect check
  (`invariants/effect/grafana_push_verify.py`). Unset ⇒ that check reports
  "inert" and passes — same dormant-until-secrets contract as the Grafana push.
```

In the workflow-inventory section, add one entry:

```markdown
- **Invariant registry** (`invariants/`, runs inside `fabric-health.yml`):
  declarative `drift`/`ttl` checks (`invariants/manifest.yml`, linted by
  `scripts/check-invariants-manifest.sh` in self-check) plus `effect` scripts
  (`invariants/effect/*.py`, exit 0/1/2 = OK/WARN/CRIT). CRITs upsert
  `Invariant violation: <id>` needs-human issues; `ttl` entries may opt into
  bounded auto-remediation (`disable-workflow`, this repo only). Design:
  `docs/design/2026-07-23-pipeline-invariant-registry-design.md`. Contribution
  rule: a PR adding a temporary override or a hand-maintained declared list must
  add a manifest entry (or state why generation made one unnecessary).
```

- [ ] **Step 2: Flip the design doc status line**

In `docs/design/2026-07-23-pipeline-invariant-registry-design.md`, change the first blockquote line to:

```markdown
> **Status:** approved; implementation plan at
> `docs/superpowers/plans/2026-07-23-pipeline-invariant-registry.md`.
```

- [ ] **Step 3: Commit, push, open the implementation PR**

```bash
git add README.md docs/design/2026-07-23-pipeline-invariant-registry-design.md
git commit -m "docs(invariants): README inventory + secrets, mark design implemented-by-plan"
git push -u origin HEAD
gh pr create --repo SuxOS/.github --title "feat: pipeline invariant registry (drift/ttl/effect checks in fabric-health)" \
  --body "Implements docs/design/2026-07-23-pipeline-invariant-registry-design.md (spec PR #712). Read-only runner + declarative manifest + two effect checks, wired into fabric-health with needs-human alert upsert and bounded disable-workflow remediation. All logic covered by scripts/test-invariants-*.sh + extraction tests in self-check."
```

- [ ] **Step 4: Live-fire verification after merge (manual, one-time)**

1. `gh workflow run self-fabric-health.yml --repo SuxOS/.github`, then `gh run watch` the run.
2. In the run log, confirm the `Run invariant registry` step prints one `OK ...` line per check (`issue-build-retry-bound`, `stale-override-sweep`, `fabric-health-cadence`, `cost_effectiveness`, `grafana_push_verify` — the last reads `inert` until its secrets exist). **Note:** `self-issue-build.yml` is currently disabled from the 2026-07-22 incident response; `issue-build-retry-bound` reads its recent-run history regardless of enablement, so it must still report OK (its trailing cancelled streak is below the bound only once the #701 fix lands and runs — if it reports CRIT here, that is the registry working, not a bug; expect a needs-human alert and confirm its body, then close it as acknowledged).
3. Confirm exactly one needs-human issue exists per CRIT (none expected on a healthy fabric), and that a re-run does not duplicate any.
4. Re-read the watched state after the watcher exits (a `gh run watch` exit is not settledness — CLAUDE.md).

---

## Explicitly not in this plan (matching the design's §9)

- The concrete #701 fix (shrink-on-retry in `issue-build.yml`, requeue double-dispatch race) — already running as its own spawned task.
- Converting `managed-repos.json` to a generated file (spec §2's prevention-over-detection example). The spec directs generation but does not design the inclusion rule it requires (which `gh repo list --org SuxOS` results count as "managed"? how are cold-tier `suxos-net`/`nix` and future archived repos classified?), and the file feeds four other workflows' matrices — that rule needs its own small design pass, tracked by #689, before a mechanical cutover is safe. Deliberately NOT re-added as a drift check either, per the spec's own §3 note.
- `pin-consistency.yml` trigger-hygiene cleanup.
- Per-repo weighted budget share (#542).
- Grafana dashboard panels for `suxos_invariant_*` (the metrics push; panels can be added later without touching this code — `scripts/test-dashboard-queries.sh` will gate them when added).
- Cross-repo remediation (needs an app token; v1 is deliberately `SuxOS/.github`-only, enforced by lint).
