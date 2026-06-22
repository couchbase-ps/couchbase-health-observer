#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/deploy/kind/couchbase-cluster"

helm dependency build "$CHART" >/dev/null

REGION_A="$(helm template region-a "$CHART" --namespace region-a)"
grep -q 'kind: Deployment' <<<"$REGION_A"
grep -Eq 'kind: "?CouchbaseCluster"?' <<<"$REGION_A"
grep -q 'name: region-a$' <<<"$REGION_A"
grep -q 'image: couchbase/server:8.0.1' <<<"$REGION_A"
grep -q 'couchbase/operator:2.9.2' <<<"$REGION_A"
grep -q 'helm.sh/chart: couchbase-operator-2.92.0' <<<"$REGION_A"
grep -q 'kind: CouchbaseBucket' <<<"$REGION_A"
grep -q 'name: observer$' <<<"$REGION_A"

REGION_B="$(
  helm template region-b "$CHART" \
    --namespace region-b \
    --values "$CHART/region-b-values.yaml"
)"
grep -q 'kind: Deployment' <<<"$REGION_B"
grep -Eq 'kind: "?CouchbaseCluster"?' <<<"$REGION_B"
grep -q 'name: region-b$' <<<"$REGION_B"

kubectl kustomize "$ROOT/deploy/kind/mock-app" >/dev/null
kubectl kustomize "$ROOT/deploy/kind/observer" >/dev/null

grep -q -- '--conn=couchbase://region-a-srv.region-a.svc' "$ROOT/deploy/kind/observer/deployment.yaml"
grep -q -- '--secondary-conn=couchbase://region-b-srv.region-b.svc' "$ROOT/deploy/kind/observer/deployment.yaml"
grep -q -- '--bucket=observer' "$ROOT/deploy/kind/observer/deployment.yaml"

echo "PASS: kind Helm releases and Kubernetes manifests render"
