# SuxOS — fabric health (dashboard as code)

S1 of the [fabric-stability v2 spec](../docs/design/2026-07-16-fabric-stability-v2-design.md).
This is the **fabric/pipeline** half of observability — the sibling of the `sux`
edge dashboards (`sux-metrics-prom`, `sux-resilience-obs`), which live in the `sux`
repo. Both push to the same Grafana Cloud stack and share the `sux` folder.

## What ships this

The reusable workflow [`fabric-health.yml`](../.github/workflows/fabric-health.yml),
scheduled every 15 min by [`self-fabric-health.yml`](../.github/workflows/self-fabric-health.yml).
One read-only cron pass over the org's repos produces `fabric-status.json` (the
single ground-truth artifact the `orient` tool reads) and pushes a low-cardinality
snapshot to Grafana Cloud the same way `sux/src/grafana.ts` does:

- **Prometheus (metrics)** — `suxos_*` series as **Influx line protocol** to the
  Grafana Cloud Influx write endpoint (`GRAFANA_PROM_URL`), Basic-auth
  `GRAFANA_PROM_USER:GRAFANA_LOKI_TOKEN`. Same endpoint + shared token as the edge.
- **Loki (events)** — one rollup line per run to `{service="suxos-fabric"}`.

**Dormant until secrets exist.** The push is a clean no-op unless the `GRAFANA_*`
secrets are set on the `.github` repo (reuse the edge's — the token just needs
`metrics:write` + `logs:write` scope). Safe to land before wiring.

## The metric series

| Series | Tags | Meaning |
| --- | --- | --- |
| `suxos_pipeline_backlog` | — | Open build-eligible issues across the org |
| `suxos_backlog_zero` | — | `1` when backlog is 0 (the streak is derived from this) |
| `suxos_budget_throttle_active` | — | `1` when ANY repo's "Autonomy throttle" tracking issue `level:` body line is not `green` (#319/#522 — body-matched, not a `throttle` label; OR across every repo in `$REPOS`) |
| `suxos_budget_throttle_active` | `repo` | Same signal, per repo — which one is throttled (#522) |
| `suxos_pr_open_total` | `repo` | Open PRs |
| `suxos_pr_red_total` | `repo` | PRs with a failing check rollup |
| `suxos_pr_stuck_total` | `repo` | PRs BEHIND/DIRTY or idle past the threshold |
| `suxos_workflow_red_total` | `repo` | Workflows whose last completed run failed |
| `suxos_merged_prs_in_window` | `repo` | PRs merged in the trailing `merged-window-hours` window (drain-controller signal, #473) |
| `suxos_drain_integral_error` | `repo` | Drain-controller PI integral term, persisted across runs (#475) |
| `suxos_recommended_parallel_batches` | `repo` | Drain-controller's recommended `parallel-batches` value, comparison-only until `use-recommended-parallel-batches` is flipped on (#475) |
| `suxos_workflow_disabled` | `repo`, `workflow` | `1` per disabled_manually/disabled_inactivity workflow (non-exempt) |
| `suxos_edge_deploy_ok` | `service` | Edge smoke check passed (opt-in via input) |
| `suxos_collector_ok` | — | Heartbeat / freshness (`1` each run) |
| `suxos_collection_ok` | `repo`, `collector` | `1` when that repo's collector query succeeded, `0` on error (#305) |

**Drain-to-zero streak (DoD):** not stored in the workflow — derived in Prometheus
from series history: `min_over_time(suxos_backlog_zero[7d]) == 1` means backlog held
at zero for 7 days. The dashboard's "Drain-to-zero streak" stat renders exactly this.

> **Why the stat panels use `last_over_time(...[20m])`, not the bare series:** the
> spine pushes every 15 min, but Prometheus treats a sample as stale after 5 min, so
> an instant query at `now` reads "No data" for ~2/3 of every interval. Wrapping each
> gauge in `last_over_time(<expr>[20m])` (window > the 15-min cadence) makes the stat
> always show the most recent tick. Keep the window above the cron interval if you
> change either.

> **Influx naming caveat** (same as the edge): if panels show "No data", the
> receiver may suffix series `_value` (`suxos_pipeline_backlog_value`). Add the
> suffix to the panel queries if so.

## Files

| File | What it is |
| --- | --- |
| `fabric-health-dashboard.json` | Importable Grafana dashboard (Prometheus), `uid: suxos-fabric-health`. Import into the `sux` folder. Links out to the `sux` dashboards and Cloudflare Workers observability. |

## Import / update

Source of truth is this file — re-import after editing (the `uid` is stable):
Grafana → Dashboards → New → Import → upload `fabric-health-dashboard.json` →
pick the Prometheus datasource for `DS_PROM` → folder `sux`.
