# Observer Deployment (Kubernetes, centralized active mode)

Answers: *how is the Observer deployed, how is it wired, what does it need?*

## Architecture

A single-replica `Deployment` (`deploy/k8s/observer.yaml`) runs the observer in
**active** mode. Each interval it pings the primary Couchbase cluster via the SDK,
computes per-service health, and — on a sustained critical outage past
`--failover-delay` — repoints the `cb-conn` ConfigMap to the secondary and rolls the
dependent app Deployments. Failback is **operator-driven** (never automatic).

## Three health signals (never conflated)

| Endpoint | Answers | Consumer | Depends on Couchbase? |
|---|---|---|---|
| `/health/couchbase` | Is the database reachable? | AWS ALB quorum path | Yes, by design |
| `/healthz` (liveness) | Is the observer's loop alive? | kubelet | No |
| `/readyz` (readiness) | Is the observer configured + wired to act? | kubelet / rollouts | No |

**Never** point liveness/readiness at `/health/couchbase`: a real outage would
restart the observer exactly when it must act. Liveness fails only for a
restart-fixable stall; readiness fails (without restart) when the K8s API is
unreachable, re-checked every period.

## Prerequisites
- A `cb-conn` ConfigMap in the namespace with key `connstring`.
- The dependent app(s) read `cb-conn` and reconnect on rollout restart.
- Image pullable: `ghcr.io/couchbase-ps/couchbase-health-observer:latest` (public).

## RBAC
`ServiceAccount` + namespaced `Role`/`RoleBinding`: `get/update/patch` ConfigMaps,
`get/list/update/patch` Deployments. No cluster-wide permissions.

## Flags
`--mode active`, `--conn`, `--secondary-conn`, `--bucket`, `--user`, `--pass`,
`--critical` (comma list, e.g. `kv`), `--interval`, `--failover-delay` (set above the
cluster auto-failover timeout so absorbed single-node losses do not trigger a switch),
`--namespace`, `--configmap`, `--config-key`, `--deployments` (comma list), `--dry-run`.

## Observability
`GET /metrics` (Prometheus). Key series: `observer_loop_last_tick_timestamp_seconds`,
`observer_couchbase_up{region}`, `observer_service_up{service}`,
`observer_sustained_down_seconds`, `observer_active_region{region}`,
`observer_failover_total`, `observer_failover_errors_total`, `observer_secondary_up`.
Alerts in `deploy/k8s/observer-alerts.yaml`.

## SPOF & HA

The centralized model runs **one** active detector — a single point of failure.
Mitigations, cheapest first:
1. **Dead-man alert** (`ObserverAbsent`) — you are paged if the observer disappears
   (shipped in `observer-alerts.yaml`).
2. **Fast reschedule** — a Deployment reschedules the pod on node loss; the
   cold-start guard prevents a mid-outage restart from auto-switching.
3. **Leader-election active-passive HA** (future) — N replicas, only the leader
   actuates. Removes the SPOF in this model. Deferred.
4. **AWS distributed-quorum path** — a fleet of observers behind an ALB target group
   + CloudWatch quorum alarm + switch Lambda removes the single detector entirely,
   at ~2–3 min failover latency. See `deploy/aws/eks-demo/`.
