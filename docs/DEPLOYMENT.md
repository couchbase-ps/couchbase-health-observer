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
- A `cb-conn` ConfigMap with key `connstring` in every target namespace.
- The dependent app(s) read `cb-conn` and reconnect on rollout restart.
- Image pullable: `ghcr.io/couchbase-ps/couchbase-health-observer:latest` (public).

## RBAC
`ServiceAccount` plus a `ClusterRole` holding `get/update` on ConfigMaps and Deployments,
bound by one `RoleBinding` per target namespace. The production manifest is
`deploy/k8s/observer.yaml`; it ships the `ClusterRole` and one `RoleBinding`, in
`default`. (`deploy/kind/observer/rbac.yaml` is the same shape for the kind test stack,
bound in `default` and `app-b`.) The verbs match the only calls `pkg/actuator` makes: Get
and Update on both resources. The observer can only touch the namespaces it is bound in,
so an unlisted namespace stays unreachable even if a target names it.

**Adding a target namespace means adding a `RoleBinding` for it** in
`deploy/k8s/observer.yaml`: same `roleRef` (the `observer` `ClusterRole`), same subject
(the `observer` `ServiceAccount` in `default`), `metadata.namespace` set to the new
namespace. Without it every Get in that namespace returns `forbidden` for the whole
outage. Teams that add namespaces often can swap the per-namespace bindings for a single
`ClusterRoleBinding` instead:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: observer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: observer
subjects:
  - kind: ServiceAccount
    name: observer
    namespace: default
```

Trade-off: no RBAC change per new namespace, but the observer then holds `get/update` on
every ConfigMap and Deployment in the cluster.

## Flags
`--actuators` (comma list: `k8s`, `webhook`, or `k8s,webhook`; empty default = observe
only), `--conn`, `--secondary-conn`, `--bucket`, `--user`, `--pass`,
`--critical` (comma list, e.g. `kv`), `--interval`, `--failover-delay` (set above the
cluster auto-failover timeout so absorbed single-node losses do not trigger a switch),
`--namespace` (default namespace for unqualified entries), `--configmap` (comma list,
`ns/name` or bare name), `--config-key` (global, all ConfigMaps), `--deployments` (comma
list, `ns/name` or bare name), `--dry-run`.

`--mode` (`observe` / `active`) is **DEPRECATED** and goes away next release; it logs a
WARN. `--mode=active` becomes `--actuators=k8s`, `--mode=observe` becomes no flag.

The Kubernetes targets above (`--namespace`, `--configmap`, `--config-key`,
`--deployments`) and the RBAC they need apply to the `k8s` actuator only. A
webhook-only observer reads no ConfigMap and needs no ServiceAccount permissions.

Webhook actuator: `--webhook-url` (required with `webhook`), `--webhook-user`,
`--webhook-pass`, `--webhook-header` (`"Key: Value"`, repeatable), `--webhook-timeout`
(default `3s`), `--webhook-retries` (default `2`), `--webhook-ca-cert`,
`--webhook-skip-verify`. Keep the credentials in a Secret and pass them as the
`WEBHOOK_USER`, `WEBHOOK_PASS` and `WEBHOOK_HEADER` (one `Key: Value` per line)
environment variables instead of Deployment args.

Budget the webhook against the liveness window: a switching tick runs both probes and
the delivery, so keep `2*probe-timeout + (retries+1)*webhook-timeout + backoff` under
`3*interval` or the observer warns `webhook_window_tight` and risks a restart mid-outage.

## Observability
`GET /metrics` (Prometheus). Key series: `observer_loop_last_tick_timestamp_seconds`,
`observer_couchbase_up{region}`, `observer_service_up{service}`,
`observer_sustained_down_seconds`, `observer_active_region{region}`,
`observer_failover_total`, `observer_failover_errors_total`, `observer_secondary_up`,
`observer_webhook_total{result}`, `observer_webhook_last_success_timestamp_seconds`.
Alerts in `deploy/k8s/observer-alerts.yaml`.

Note: `observer_secondary_up` is set only when a switch is pending (sustained outage),
so it reads `0` until the first switch attempt — read it alongside `observer_couchbase_up`
(the `ObserverSwitchHeldSecondaryDown` alert already gates on both).

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
