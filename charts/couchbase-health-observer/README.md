# couchbase-health-observer

Helm chart for the Couchbase health observer: it probes a Couchbase cluster, serves the
verdict over HTTP and Prometheus, and can repoint applications at a secondary cluster on
a sustained outage.

> **Support status.** Delivered and maintained on a best-effort basis by the Couchbase
> Delivery team. This is not a Couchbase product release. It does not go through the
> product release train, it is not on the product documentation site, and it is not
> covered by product support or a product SLA.

## Requirements

- Kubernetes 1.23 or later
- Helm 3.8 or later (needed for the OCI registry path)
- The Prometheus Operator CRDs, only if you enable `monitoring.*`

## Install

From the OCI registry:

```bash
helm install observer oci://ghcr.io/couchbase-ps/charts/couchbase-health-observer \
  --version 0.5.0 \
  --namespace observer --create-namespace \
  --values my-values.yaml
```

From a packaged archive, for a pipeline that cannot pull OCI charts. Download
`couchbase-health-observer-<version>.tgz` from the GitHub release, then:

```bash
helm install observer ./couchbase-health-observer-0.5.0.tgz \
  --namespace observer --create-namespace \
  --values my-values.yaml
```

Keep your own values file in your own pipeline. The examples in `values-examples/` are
generic starting points: `actuator.yaml` (full switch), `observe-only.yaml` (passive
sensor), `kind.yaml` (the end-to-end test stack).

## What it renders

| Object | Condition |
|---|---|
| Deployment, Service | always |
| ServiceAccount | `serviceAccount.create` |
| Secret | credentials given inline, and no `existingSecret` |
| ClusterRole, one RoleBinding per target namespace | `k8s` in `actuators` and `rbac.create` |
| CA Secret | `tls.caCert` or `webhook.caCert` given inline |
| PrometheusRule | `monitoring.prometheusRule.enabled` |
| ServiceMonitor | `monitoring.serviceMonitor.enabled` |

## Actuators

`actuators` names what the observer does when a switch is due.

| Value | Effect |
|---|---|
| `""` | observe only: serve `/health/couchbase` and the metrics, actuate nothing, need no RBAC |
| `k8s` | patch every target ConfigMap and roll every target Deployment |
| `webhook` | POST the switch request to `webhook.url`, touch nothing in Kubernetes |
| `k8s,webhook` | both. The latch follows the `k8s` result; a webhook failure logs an error and never blocks the switch |

Failover is automatic, failback is always manual.

## Credentials

Credentials never reach the container arguments. The chart renders `--user=$(CB_USER)`
and `--pass=$(CB_PASS)`, and Kubernetes expands `$(VAR)` from the environment, which is
populated from a Secret.

- Inline `couchbase.username` and `couchbase.password` put the values in a chart-managed
  Secret, which means they also live in the Helm release history. Fine for evaluation.
- `couchbase.existingSecret` points at a Secret you create yourself, and wins over the
  inline values. Use it in production, and set `usernameKey` and `passwordKey` to match.

The webhook credentials behave the same way through `webhook.existingSecret`, and the
observer reads them from `WEBHOOK_USER`, `WEBHOOK_PASS` and `WEBHOOK_HEADER`.

## TLS

For a `couchbases://` connection, give the CA either inline as `tls.caCert` or as
`tls.existingCaSecret`. The chart mounts it read-only at `/etc/observer/tls` and sets
`--tls-cert-path` for you. `tls.skipVerify` exists for a lab and logs a warning at
startup. The webhook CA works the same way at `/etc/observer/webhook-ca`.

## RBAC

One ClusterRole holds the verbs, `get` and `update` on `configmaps` and
`apps/deployments`. One RoleBinding per target namespace grants them there only, so an
unlisted namespace stays unreachable even when a target names it. The chart never
renders a ClusterRoleBinding.

The namespace set is derived from the targets: an entry `app-b/cb-conn` yields `app-b`,
an unqualified entry yields `targets.namespace`. Set `rbac.namespaces` to override the
derivation.

## Values

| Key | Default | Meaning |
|---|---|---|
| `replicaCount` | `1` | Single active detector. More replicas duplicate the probing and the actuation. |
| `image.repository` | `ghcr.io/couchbase-ps/couchbase-health-observer` | Image. |
| `image.tag` | `""` | Empty means the chart `appVersion`. Never `latest`. |
| `image.pullPolicy` | `Always` | |
| `fullnameOverride` | `""` | Set to keep an existing install's object names. |
| `actuators` | `k8s` | See above. |
| `couchbase.connString` | `couchbase://localhost` | Primary cluster. |
| `couchbase.secondaryConnString` | `""` | Empty means no switch is possible. |
| `couchbase.bucket` | `travel-sample` | Bucket used for the probe. |
| `couchbase.criticalServices` | `kv` | Comma-separated. Losing one makes the cluster DOWN. |
| `couchbase.username`, `couchbase.password` | `Administrator`, `password` | Inline credentials. |
| `couchbase.existingSecret` | `""` | Wins over the inline credentials. |
| `couchbase.usernameKey`, `couchbase.passwordKey` | `username`, `password` | Secret keys. |
| `detector.interval` | `5s` | Probe period. |
| `detector.probeTimeout` | `2s` | Per-probe timeout. |
| `detector.failoverDelay` | `150s` | Sustained DOWN before a switch. Anti-flap. |
| `detector.logLevel` | `info` | `trace`, `debug`, `info`, `warn`, `error`. |
| `detector.dryRun` | `false` | Decide and log, change nothing. |
| `targets.namespace` | `default` | Namespace for unqualified entries. |
| `targets.configmaps` | `cb-conn` | Comma-separated `name` or `namespace/name`. |
| `targets.configKey` | `connstring` | Key inside each ConfigMap. |
| `targets.deployments` | `""` | Deployments to roll after the patch. |
| `rbac.create` | `true` | |
| `rbac.namespaces` | `[]` | Empty derives the set from the targets. |
| `tls.caCert`, `tls.existingCaSecret`, `tls.caSecretKey` | `""`, `""`, `ca.pem` | Couchbase CA. |
| `tls.skipVerify` | `false` | Insecure. |
| `webhook.url` | `""` | Required when the webhook actuator is on. |
| `webhook.username`, `webhook.password`, `webhook.existingSecret` | `""` | Webhook credentials. |
| `webhook.headers` | `[]` | Each entry is `Key: Value`. |
| `webhook.headersKey` | `""` | Read the header set from a Secret key instead. |
| `webhook.timeout`, `webhook.retries` | `3s`, `2` | |
| `webhook.caCert`, `webhook.existingCaSecret`, `webhook.skipVerify` | `""`, `""`, `false` | Webhook TLS. |
| `service.type`, `service.port` | `ClusterIP`, `8080` | |
| `monitoring.serviceMonitor.enabled` | `false` | Needs the ServiceMonitor CRD. |
| `monitoring.prometheusRule.enabled` | `false` | Needs the PrometheusRule CRD. |
| `monitoring.prometheusRule.job` | `observer` | The scrape job label the alerts select on. |
| `extraArgs` | `[]` | Appended after the generated arguments. |
| `resources`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `podLabels` | | Standard. |

## Labels

Objects carry the standard Helm labels, so select the pods with
`app.kubernetes.io/name=couchbase-health-observer` (add
`app.kubernetes.io/instance=<release>` when several releases share a namespace). The
hand-written manifest used `app: observer` before this chart existed: update any
dashboard, scrape config or script that still selects on it.

## Probes

Liveness is `/healthz` (the loop is alive) and readiness is `/readyz` (the Kubernetes API
is reachable). Never repoint either at `/health/couchbase`: a Couchbase outage would then
restart the observer exactly when it must act.

## Without Helm

`deploy/k8s/observer.yaml` is generated from this chart and applies with `kubectl`. It is
a generated file: change the chart and run `hack/render-manifests.sh`, never edit it
directly.
