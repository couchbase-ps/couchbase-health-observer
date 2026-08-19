# deploy/k8s — centralized Observer (production manifest)

Applies the active-mode Observer that repoints `cb-conn` and rolls dependent apps
on a sustained primary outage.

    kubectl apply -f deploy/k8s/observer.yaml
    kubectl apply -f deploy/k8s/observer-alerts.yaml   # needs the Prometheus Operator (PrometheusRule CRD)

## Probe wiring (do not change)

| Probe | Path | Fails when | Effect |
|-------|------|-----------|--------|
| liveness | `/healthz` | active loop stalled (>3x interval) | pod restarted |
| readiness | `/readyz` | K8s API unreachable / not yet evaluated | pod marked NOT READY (no restart) |
| (DB health) | `/health/couchbase` | Couchbase unreachable | consumed by the AWS ALB path only |

**Never** point liveness/readiness at `/health/couchbase` — a DB outage would restart
the observer exactly when it must act. See `docs/DEPLOYMENT.md`.

Metrics: `GET /metrics` (Prometheus). Alerts: `deploy/k8s/observer-alerts.yaml`.

## Actuators

`--actuators` replaces `--mode`. It names what the observer does when a switch is due:

| value | effect |
|---|---|
| (empty, default) | observe only: serve `/health/couchbase`, run no loop |
| `k8s` | patch every connstring ConfigMap and roll every Deployment named by `--configmap`/`--deployments` (previous `--mode=active`) |
| `webhook` | POST the switch request to `--webhook-url`, touch nothing in Kubernetes |
| `k8s,webhook` | both; the switch latches on the k8s result alone, webhook failure logs an error but never blocks it |

The latch always follows whichever actuator can actually move the applications:
with `k8s` enabled it is the actuator, so its result decides; `webhook` is then
just a notification. Only when `webhook` is the sole actuator does its result
decide the latch, same as before.

A webhook-only observer needs no ServiceAccount permissions at all: it reads no
ConfigMap and rolls no Deployment.

**Upgrading:** `--mode` still works for one release and logs a deprecation WARN.
Move `--mode=active` to `--actuators=k8s` when you next edit the manifest.

Credentials belong in a Secret, read from `WEBHOOK_USER`, `WEBHOOK_PASS` and
`WEBHOOK_HEADER` (one `Key: Value` per line), not in the Deployment args.

The webhook payload is declarative: it names the cluster the applications should
point at in `to.conn`. A receiver must check the live connection string first and
do nothing when it already matches, because a restarted observer re-sends the
same request while the primary is still down.

`configmaps` and `deployments` describe the Kubernetes actuator's targets. Each
entry is namespace-qualified (`"urp-dev/cb-conn"`), because one switch spans
several namespaces and there is no single namespace to report. Both are omitted
when they carry nothing to say (a webhook-only switch has no Kubernetes targets
of its own), so treat both as optional. `event`, `to` and `actuators` are always
present.
