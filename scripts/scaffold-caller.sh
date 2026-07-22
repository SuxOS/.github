#!/usr/bin/env bash
#
# Scaffold the SuxOS caller-stub set for a repo.
#
# Every SuxOS repo inherits the shared pipeline in SuxOS/.github by dropping a
# thin `workflow_call` caller stub for each reusable workflow into its own
# `.github/workflows/`. This script emits that whole set in one shot, with the
# event triggers that can't cross the `workflow_call` boundary (`workflow_run`,
# `schedule`, `issues`, `pull_request`, ...) already declared in the caller —
# the manual transcription the README's "Caller-stub pattern" section describes.
#
# Usage:
#   scripts/scaffold-caller.sh [options]
#
# Options:
#   -o, --out-dir DIR          Where to write the stubs (default: .github/workflows)
#   -w, --wrangler-config PATH Wrangler config for CI's dry-run deploy + autofix.
#                              Pass "" for a repo that deploys no Worker (default:
#                              sux/wrangler.jsonc, mirroring sux-mcp).
#   -r, --ref REF              Git ref of SuxOS/.github to pin `uses:` to
#                              (default: main).
#   -f, --force                Overwrite existing stub files.
#   -h, --help                 Show this help.
#
# After scaffolding, finish the manual steps the generator can't do (see the
# README "Required secrets/vars" section): set the org-level secrets, create the
# labels, and turn on branch protection.

set -euo pipefail

OUT_DIR=".github/workflows"
WRANGLER_CONFIG="sux/wrangler.jsonc"
REF="main"
FORCE=0

die() { echo "scaffold-caller: $*" >&2; exit 1; }

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out-dir)         OUT_DIR="${2:?}"; shift 2 ;;
    -w|--wrangler-config) [ $# -ge 2 ] || die "missing value for $1 (pass \"\" for no Worker)"; WRANGLER_CONFIG="$2"; shift 2 ;;
    -r|--ref)             REF="${2:?}"; shift 2 ;;
    -f|--force)           FORCE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "unknown option: $1 (try --help)" ;;
  esac
done

REPO="SuxOS/.github"
mkdir -p "$OUT_DIR"

# emit NAME <<'YAML' ... YAML  — writes $OUT_DIR/NAME.yml, honouring --force.
# Checks both the .yml and .yaml extension before writing (mirroring
# check-caller-conformance.sh's treatment of them as interchangeable) so a caller's
# customized NAME.yaml stub is never shadowed by a freshly-scaffolded NAME.yml (#568).
emit() {
  local dest="$OUT_DIR/$1.yml"
  local alt="$OUT_DIR/$1.yaml"
  if [ "$FORCE" -ne 1 ]; then
    if [ -e "$dest" ]; then
      echo "skip   $dest (exists; --force to overwrite)"
      return
    fi
    if [ -e "$alt" ]; then
      echo "skip   $alt (exists; --force to overwrite)"
      return
    fi
  fi
  cat > "$dest"
  echo "wrote  $dest"
}

# --- Gates -----------------------------------------------------------------

# claude-autofix is job-chained here, not its own caller-stub file: workflow_run (the
# only way a separate stub could listen for "CI failed") structurally never fires for a
# PR-branch CI run (SuxOS/.github#260) — same-workflow job chaining doesn't have that
# failure mode. github.event_name == 'pull_request' keeps it from firing on push/merge_group.
#
# NOTE (#579): no current managed repo actually wires the reusable ci.yml this stub
# calls — each forked its own ci.yml instead (see
# docs/design/2026-07-22-ci-yml-fate-decision.md). Treat this emitted stub as a
# starting template to adapt (or replace with your own ci.yml keeping the `autofix`
# job below), not a proven-live default.
emit ci <<YAML
name: CI
on:
  push:
  pull_request:
jobs:
  ci:
    uses: $REPO/.github/workflows/ci.yml@$REF
    with:
      wrangler-config: "$WRANGLER_CONFIG"
    secrets: inherit

  autofix:
    needs: [ci]
    if: needs.ci.result == 'failure' && github.event_name == 'pull_request'
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
    uses: $REPO/.github/workflows/claude-autofix.yml@$REF
    with:
      pr-number: \${{ github.event.pull_request.number }}
      head-branch: \${{ github.event.pull_request.head.ref }}
      head-sha: \${{ github.event.pull_request.head.sha }}
      base-branch: \${{ github.event.pull_request.base.ref }}
      gates-summary: "npm run type-check · npm test"
    secrets: inherit
YAML

emit security-review <<YAML
name: Security review
# ready_for_review is required: the reusable skips draft PRs, and GitHub counts a
# skipped required check as passing — omitting this type lets a PR go ready+merge
# without the review ever re-running. (Every hand-written caller stub in the org
# already carries this; this template used to lag them — see SuxOS/.github#144-era
# audit finding.)
#
# pull_request_target is added ONLY to route Dependabot dep-bump PRs through a
# secret-bearing base-repo context: GitHub withholds secrets (incl.
# CLAUDE_CODE_OAUTH_TOKEN) from Dependabot pull_request runs, so the review goes inert
# and this REQUIRED gate fails CLOSED forever on every dep bump (SuxOS/.github#621/#622).
# The job \`if\` routes each PR to EXACTLY ONE trigger — dependabot[bot] →
# pull_request_target, everyone else → pull_request — so the review never double-runs and
# no untrusted human PR reaches the privileged context. Mirrors self-automerge.yml's
# proven handling of the Dependabot actor. Harmless for a repo without Dependabot (the
# pull_request_target path simply never fires).
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  security-review:
    if: >-
      (github.event_name == 'pull_request' && github.event.pull_request.user.login != 'dependabot[bot]') ||
      (github.event_name == 'pull_request_target' && github.event.pull_request.user.login == 'dependabot[bot]')
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    uses: $REPO/.github/workflows/security-review.yml@$REF
    with:
      # dependabot[bot] must be allowed or claude-code-action refuses the bot PR and hard-fails
      # this required gate (a mechanical block, not a finding). suxbot[bot] stays for bot builds.
      allowed-bots: "suxbot[bot],dependabot[bot]"
    secrets: inherit
YAML

emit audit <<YAML
name: Audit
on:
  pull_request:
jobs:
  audit:
    uses: $REPO/.github/workflows/audit.yml@$REF
    secrets: inherit
YAML

emit health <<YAML
name: Health
on:
  schedule: [{ cron: "0 * * * *" }]
  workflow_dispatch:
jobs:
  health:
    uses: $REPO/.github/workflows/health.yml@$REF
    secrets: inherit
YAML

# --- Autonomy pipeline -----------------------------------------------------

# unlabeled is required, not cosmetic: removing the `hold` label fires `unlabeled`, and
# without that type automerge won't re-run to re-arm. pull_request_review is deliberately
# absent — automerge eligibility no longer reads reviews (the whole predicate is
# draft+hold), so listening for review submission is dead weight. Matches what every live
# caller converged on (sux/suxlib/suxrouter; claude-config alone still carries the review
# trigger as a holdover — not the shape to scaffold forward).
emit automerge <<YAML
name: Automerge
on:
  pull_request_target:
    types: [opened, reopened, ready_for_review, synchronize, labeled, unlabeled, edited]
jobs:
  automerge:
    uses: $REPO/.github/workflows/automerge.yml@$REF
    secrets: inherit
YAML

emit pr-auto-update <<YAML
name: PR auto-update
on:
  push:
    branches: [main]
jobs:
  pr-auto-update:
    uses: $REPO/.github/workflows/pr-auto-update.yml@$REF
    secrets: inherit
YAML

emit pr-drain <<YAML
name: PR drain
on:
  schedule: [{ cron: "0 3 * * *" }]
  workflow_dispatch:
jobs:
  pr-drain:
    uses: $REPO/.github/workflows/pr-drain.yml@$REF
    secrets: inherit
YAML

emit pr-watch <<YAML
name: PR watch
on:
  schedule: [{ cron: "0 */6 * * *" }]
  workflow_dispatch:
jobs:
  pr-watch:
    uses: $REPO/.github/workflows/pr-watch.yml@$REF
    secrets: inherit
YAML

# Deliberately slow (daily) — pr-unstick is a patient long-lived-unstuck mechanism, not
# a fast retry loop. See pr-unstick.yml's header for why.
emit pr-unstick <<YAML
name: PR unstick
on:
  schedule: [{ cron: "23 4 * * *" }]
  workflow_dispatch:
jobs:
  pr-unstick:
    uses: $REPO/.github/workflows/pr-unstick.yml@$REF
    secrets: inherit
YAML

emit claude <<YAML
name: Claude
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  issues:
    types: [opened, assigned]
jobs:
  claude:
    uses: $REPO/.github/workflows/claude.yml@$REF
    secrets: inherit
YAML

emit skill-sync <<YAML
name: Skill sync
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  skill-sync:
    uses: $REPO/.github/workflows/skill-sync.yml@$REF
    secrets: inherit
YAML

# --- Backlog pipeline (propose -> investigate -> build) --------------------

# 3-tier propose cadence, standardized org-wide 2026-07-17
# (docs/design/2026-07-17-automation-structure-and-anti-drift.md, propose row): 15m
# bugs-only / 30m bugs+feats / 1h deep, each its own stub so a distinct workflow name ->
# distinct concurrency group (fixer.yml's group key is `fixer-${{ github.workflow }}`) and
# none blocks on or races the others. Mirrors this repo's own self-fixer-bugs.yml /
# self-fixer-30m.yml / self-fixer.yml pins (model: sonnet — operator directive
# 2026-07-17: sonnet pinned org-wide, no Opus escalation). All three wire the SAME
# fixer.yml reusable under different `scope`/`max-turns`/cron — see
# check-caller-conformance.sh's CANON_TARGETS derivation for why that multiplexing needs
# its own handling in check (a) (#368).

emit fixer-bugs <<YAML
name: Fixer (15m, bugs only)
on:
  schedule: [{ cron: "9,24,39,54 * * * *" }]
  workflow_dispatch:
jobs:
  fixer:
    uses: $REPO/.github/workflows/fixer.yml@$REF
    with:
      model: sonnet # operator directive 2026-07-17: sonnet pinned org-wide, no Opus escalation
      max-turns: 10
      scope: bugs
    secrets: inherit
YAML

emit fixer-30m <<YAML
name: Fixer (30m, bugs+feats)
on:
  schedule: [{ cron: "14,44 * * * *" }]
  workflow_dispatch:
jobs:
  fixer:
    uses: $REPO/.github/workflows/fixer.yml@$REF
    with:
      model: sonnet # operator directive 2026-07-17: sonnet pinned org-wide, no Opus escalation
      max-turns: 15
      scope: bugs-feats
    secrets: inherit
YAML

emit fixer <<YAML
name: Fixer (1h, deep)
on:
  schedule: [{ cron: "29 * * * *" }]
  workflow_dispatch:
jobs:
  fixer:
    uses: $REPO/.github/workflows/fixer.yml@$REF
    with:
      model: sonnet # operator directive 2026-07-17: sonnet pinned org-wide, no Opus escalation
      max-turns: 40
      scope: deep
    secrets: inherit
YAML

# Hourly cron (not the old 4x/day batch — every live caller converged on hourly) plus an
# `issues: [labeled]` event trigger so a freshly-labelled bug/enhancement/documentation
# issue can build well before the next cron tick, same as sux/suxlib/suxrouter/claude-config
# already do. The label-type filter lives in the job's own `if:` (not the trigger) since
# `on.issues.types` can only filter the ACTION (labeled/opened/...), not which label was
# applied — stagger the cron minute per repo so concurrent repos don't stack sessions
# inside one 5-hour subscription window.
emit issue-build <<YAML
name: Issue build
on:
  schedule: [{ cron: "7 * * * *" }]
  workflow_dispatch:
  issues:
    types: [labeled]
jobs:
  issue-build:
    if: github.event_name != 'issues' || contains(fromJSON('["bug","enhancement","documentation"]'), github.event.label.name)
    uses: $REPO/.github/workflows/issue-build.yml@$REF
    with:
      gates-summary: "npm run type-check · npm test"
      model-hint: sonnet # operator directive 2026-07-17: sonnet pinned org-wide, no Opus escalation
    secrets: inherit
YAML

cat <<'DONE'

Caller stubs scaffolded. Remaining manual steps (see README):
  - Set org-level secrets: CLAUDE_CODE_OAUTH_TOKEN, SUX_BOT_APP_ID,
    SUX_BOT_PRIVATE_KEY. (CI billing is subscription-based via
    CLAUDE_CODE_OAUTH_TOKEN — ANTHROPIC_API_KEY is retired, do not set it.)
  - Create labels: building, needs-human, automerge, hold, tracking, epic (the
    nonbuildable-labels floor), bug, enhancement, documentation, security,
    effort:small, effort:medium, effort:large (the fixer's proposal-typing labels).
  - Protect main with a repository RULESET (Settings → Rules → Rulesets), NOT
    classic branch protection: assert-branch-protection.yml runs with the App
    token, and GitHub hard-403s a classic-protection read for App tokens (a
    platform wall, not a permissions bug) — a classic-only setup reads as
    unprotected and automerge refuses to arm. Require Type-check & build,
    security-review, npm audit & SBOM on the ruleset. Secret scanning is
    GitHub's native secret-scanning + push-protection (repo Settings →
    Security), not a status check — enable it there, not as a required gate.
DONE
