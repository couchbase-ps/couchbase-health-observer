# Observer Deployment (Kubernetes, centralized active mode)

Answers: *how is the Observer deployed, how is it wired, what does it need?*

## Install path

Helm is the primary path:

```bash
helm install observer oci://ghcr.io/couchbase-ps/charts/couchbase-health-observer \
  --version X.Y.Z --namespace observer --create-namespace --values my-values.yaml
```

Values reference, credential handling, TLS mounts and RBAC derivation:
[../charts/couchbase-health-observer/README.md](../charts/couchbase-health-observer/README.md).
A packaged `.tgz` hangs off each GitHub release for pipelines that cannot pull OCI charts.

`kubectl apply -f deploy/k8s/observer.yaml` stays supported for teams that do not use
Helm. That file is **generated** from the chart by `hack/render-manifests.sh`, and CI
fails when it drifts, so change the chart and regenerate rather than editing it.

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
- Image pullable: `ghcr.io/couchbase-ps/couchbase-health-observer` (public). Pin the tag;
  the chart pins it to the chart `appVersion` for you.

## RBAC
`ServiceAccount` plus a `ClusterRole` holding `get/update` on ConfigMaps and Deployments,
bound by one `RoleBinding` per target namespace. The production manifest is
`deploy/k8s/observer.yaml`; it ships the `ClusterRole` and one `RoleBinding`, in
`default`. (The chart derives the binding set from the targets, so the kind values file
with two target namespaces renders bindings in `default` and `app-b`.) The verbs match the only calls `pkg/actuator` makes: Get
and Update on both resources. The observer can only touch the namespaces it is bound in,
so an unlisted namespace stays unreachable even if a target names it.

**Adding a target namespace** with Helm means nothing extra: name the target in
`targets.configmaps` or `targets.deployments` and the binding follows. Without Helm, add
the `RoleBinding` by hand in `deploy/k8s/observer.yaml`: same `roleRef` (the `observer` `ClusterRole`), same subject
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

Note: `observer_couchbase_up{region}` reports the ACTIVE cluster only: `--conn` until a
switch, `--secondary-conn` after one (or after an already-switched state adopted at boot).
The abandoned cluster's series is dropped on the switch, so it cannot sit at `0` forever
and alert about a cluster nobody probes; `observer_active_region{region}` is what reports
the switch itself. A `--dry-run` switch patches nothing, so health stays on the primary
and logs `probe_target_held`.

Note: `observer_secondary_up` is set only when a switch is pending (sustained outage),
so it reads `0` until the first switch attempt — read it alongside `observer_couchbase_up`
(the `ObserverSwitchHeldSecondaryDown` alert already gates on both).

## OpenShift

Validated with chart 0.5.1 on OpenShift Local (CRC 2.64.0, OpenShift 4.22.14,
Kubernetes 1.35, arm64), two application namespaces, `actuators: k8s`.

- **SCC: `restricted-v2`, nothing extra.** Do not grant `anyuid` or any other SCC to the
  observer service account. The chart sets `runAsNonRoot`, `seccompProfile:
  RuntimeDefault`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` and
  `readOnlyRootFilesystem: true`, and leaves `runAsUser`, `runAsGroup` and `fsGroup`
  unset. OpenShift injects a UID from the namespace range (for example `1000670000`) and
  the observer runs as that UID. The same defaults pass Pod Security Admission
  `restricted` on plain Kubernetes, where the image user (UID 65532) applies.
- **Install** is the normal Helm command. RBAC renders as on any cluster: one
  `ClusterRole` and one `RoleBinding` per target namespace, no `ClusterRoleBinding`.
- **No Route.** The Service is cluster-internal. Use `oc port-forward svc/<release> 8080`
  to read `/health/couchbase` by hand.
- **Monitoring.** The ServiceMonitor and PrometheusRule (`monitoring.serviceMonitor`,
  `monitoring.prometheusRule`) need user-workload monitoring
  (`enableUserWorkload: true` in the `cluster-monitoring-config` ConfigMap of
  `openshift-monitoring`). The CRDs ship with OpenShift, so the objects install even
  without it, but nothing scrapes them. On CRC the monitoring stack is off by default:
  the objects were created and accepted, the scrape and the alerts were not exercised.
- **Image.** Pull from `ghcr.io` as usual, or mirror the image into the internal
  registry. A binary Docker build (`oc new-build --binary --strategy=docker`) of the
  repository builds the same image inside the cluster.

Checks passed on CRC: chart install, pod admitted under `restricted-v2` with an injected
UID, `/healthz` `/readyz` `/health/couchbase` `/metrics`, `--dry-run` switch that patched
nothing, full primary outage switch (both ConfigMaps patched, both Deployments rolled,
apps on the secondary about 39 s after the outage with `failoverDelay: 30s`), restart
adoption with no second roll (`adopt_switched`), and manual failback as in
[RUNBOOK-failover-failback.md](RUNBOOK-failover-failback.md).

The test Couchbase clusters used the Docker Hub `couchbase/server` image through the
Couchbase Helm chart, which runs as UID 1000. They needed the `anyuid` SCC in their own
namespaces. This is a test-harness concern, not an observer requirement. A production
cluster on OpenShift uses the certified Couchbase operator and images.

## SPOF & HA

The centralized model runs **one** active detector — a single point of failure.
Mitigations, cheapest first:
1. **Dead-man alert** (`ObserverAbsent`) — you are paged if the observer disappears
   (shipped in `observer-alerts.yaml`).
2. **Fast reschedule** — a Deployment reschedules the pod on node loss; at boot the
   observer adopts an already-switched ConfigMap (`adopt_switched`), so a restart after
   a switch does not switch or roll again.
3. **Leader-election active-passive HA** (future) — N replicas, only the leader
   actuates. Removes the SPOF in this model. Deferred.
4. **AWS distributed-quorum path** — a fleet of observers behind an ALB target group
   + CloudWatch quorum alarm + switch Lambda removes the single detector entirely,
   at ~2–3 min failover latency. See `deploy/aws/eks-demo/`.
