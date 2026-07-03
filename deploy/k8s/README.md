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
