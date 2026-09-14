#!/usr/bin/env bash
# Regenerates the plain manifests under deploy/k8s from the Helm chart, so the
# two never drift. CI runs this and fails on any diff. Do not hand-edit the
# generated files: edit the chart and run this.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/couchbase-health-observer"
VALUES="$CHART/values-examples/actuator.yaml"

header() {
  cat <<'HDR'
# GENERATED FILE. Do not edit.
# Source: charts/couchbase-health-observer + values-examples/actuator.yaml
# Regenerate: hack/render-manifests.sh
#
# PROBE WIRING (do NOT change): livenessProbe -> /healthz (loop alive),
# readinessProbe -> /readyz (K8s API reachable). NEVER point either probe at
# /health/couchbase: a real Couchbase outage would then restart the observer
# exactly when it must act.
HDR
}

# Drop the managed-by label: these objects are applied with kubectl, so claiming
# Helm ownership would be false and would confuse a later helm adoption.
strip_managed_by() { sed '/app.kubernetes.io\/managed-by: Helm/d'; }

{
  header
  helm template observer "$CHART" --namespace default --values "$VALUES" | strip_managed_by
} > "$ROOT/deploy/k8s/observer.yaml"

{
  header
  helm template observer "$CHART" --namespace default --values "$VALUES" \
    --set monitoring.prometheusRule.enabled=true \
    --show-only templates/prometheusrule.yaml | strip_managed_by
} > "$ROOT/deploy/k8s/observer-alerts.yaml"

echo "rendered deploy/k8s/observer.yaml and deploy/k8s/observer-alerts.yaml"
