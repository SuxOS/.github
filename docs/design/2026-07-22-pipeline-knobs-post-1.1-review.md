# Post-1.1 pipeline knobs review (#680)

Date: 2026-07-22. Status: reviewed; two knobs already re-derived by prior PRs, the
rest are cross-repo checks this session's `gh` token cannot reach (see Scope note).

## Scope note

This builder session's `gh` token is scoped to `SuxOS/.github` only (documented
gotcha, this file's own repo — see CLAUDE.md "A builder session's own `gh auth
status` token"). Items that live in *caller* repos (`sux`, `suxrouter`,
`claude-config`, `suxlib`, `suxdash`) — their `workflow_call` stub crons,
drummer configs, per-repo `hold` labels — cannot be enumerated from here. Those
rows below are marked **needs human/broader-access pass** rather than guessed at.

## Outcome table

| Knob | Current value | Why | Review-by | Status |
|---|---|---|---|---|
| Fixer cadences (this repo) | `self-fixer-bugs.yml` change-triggered (push to main), `self-fixer-30m.yml` `44 */12 * * *` (12h), `self-fixer.yml` `29 6 */3 * *` (3d) — all gated by `fixer.yml`'s backlog-high-water check | Re-derived by #637 ("Fixer Cadence v2", landed 2026-07-21) *after* the crunch-era 15m/30m/1h metronome trim this issue was filed against — the reframe makes cadence track code-change + backlog headroom instead of the clock, which subsumes the "re-evaluate against current budget headroom" ask | 2026-08-21 (30d after #637) | **Done via #637** — no further change needed now; re-check if `suxbot`'s Enterprise-pool/PAT-migration headroom claim (unverifiable from this repo — lives on claude.ai's usage page per `docs/design/budget-and-cadence.md`) still holds at review-by |
| Fixer cadences (caller repos) | unknown from this session | same v2 reframe needs porting to each caller's thin stub, if they still run pre-v2 crons | — | **needs human/broader-access pass** |
| Governor "2x" ceiling multiplier | `OPUS_BUDGET_MIN: "900"`, `TOTAL_BUDGET_MIN: "12000"` (steady-state) | PR #643 doubled both to 1800/24000 as a temporary v4-closeout push allowance; PR #653 explicitly reverted to steady-state 900/12000 once the push ended | n/a — already closed out | **Done via #653**, no open multiplier to remove |
| Five-hour-window blindness | live rate-limit scan (`budget-governor.yml` "Scan recent failed Claude runs for a live five-hour rate-limit" step) forces `red` on an actual account-level rate-limit hit, independent of the runner-minute proxy | Landed as part of the bucket-headroom rework (see `docs/design/budget-governor-reconciliation.md`); the issue's "#600/#627 may or may not have landed" hedge — those two issue numbers as currently filed are unrelated (fabric-health escalation path, loop-heartbeat registry), so the actual fix already ships under a different PR | n/a | **Done**, already live |
| Disabled workflows (this repo) | `gh workflow list --all` — all 30 workflows in `SuxOS/.github` report `active` | swept per issue ask #3 | 2026-09-01 | **Clean**, nothing to re-enable/remove |
| Disabled workflows (caller repos) | unknown from this session | same sweep, per caller | — | **needs human/broader-access pass** |
| Throttle pins (`throttle-manual` label) | none open in this repo (`gh issue list --label throttle-manual` empty) | swept per issue ask #3 | 2026-09-01 | **Clean** |
| `hold` labels older than 48h (this repo) | none open (`gh issue list --label hold` empty) | swept per issue ask #3 | 2026-09-01 | **Clean** |
| `hold` labels older than 48h (caller repos) | unknown from this session | same sweep, per caller | — | **needs human/broader-access pass** |
| Drummer cadences (`*/30` audit/drive) | self-disarming per issue's own description | issue states these already self-disarm; no config lives in this repo to change | — | **No action** — confirmed self-disarming, not a stale override |
| Drummer cadences (bughunt 2h, mychart-doors 1h) | run indefinitely, config not in this repo | need a cost/value check against actual finding rate — that data (drummer run logs, finding counts) lives in the caller repo(s), not here | — | **needs human/broader-access pass** |

## Recommendation

Two of the five sub-asks (governor multiplier, fixer cadence re-derivation) were
already resolved by prior PRs before this review ran; the within-repo sweep for
stale overrides (disabled workflows, throttle pins, `hold` labels) came back
clean. The remaining sub-asks are all per-caller-repo checks that need either a
human with cross-repo `gh` access or a future session running from inside each
caller repo — filing a single cross-repo issue from here would just get
re-dropped like #484/#492/#506 for the same access-scope reason.
