#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/deploy/kind/couchbase-cluster"

helm dependency build "$CHART" >/dev/null

REGION_A="$(
  helm template region-a "$CHART" \
    --namespace region-a \
    --values "$CHART/region-a-values.yaml"
)"
grep -q 'kind: Deployment' <<<"$REGION_A"
grep -Eq 'kind: "?CouchbaseCluster"?' <<<"$REGION_A"
grep -q 'name: region-a$' <<<"$REGION_A"
grep -q 'image: couchbase/server:8.0.1' <<<"$REGION_A"
grep -q 'couchbase/operator:2.9.2' <<<"$REGION_A"
grep -q 'helm.sh/chart: couchbase-operator-2.92.0' <<<"$REGION_A"
grep -q 'kind: CouchbaseBucket' <<<"$REGION_A"
grep -q 'name: observer$' <<<"$REGION_A"
# region-a topology: 3 data + 2 index/query, short auto-failover, bucket replica 1,
# operator-computed pod resources
grep -q 'autoFailoverTimeout: 5s' <<<"$REGION_A"
grep -q 'autoFailoverMaxCount: 1' <<<"$REGION_A"
grep -A4 'autoResourceAllocation' <<<"$REGION_A" | grep -q 'enabled: true'
grep -A3 'name: data' <<<"$REGION_A" | grep -q 'size: 3'
grep -A4 'name: query' <<<"$REGION_A" | grep -q 'size: 2'
grep -A8 'name: observer' <<<"$REGION_A" | grep -q 'replicas: 1'

REGION_B="$(
  helm template region-b "$CHART" \
    --namespace region-b \
    --values "$CHART/region-b-values.yaml"
)"
# common values still apply to region-b
grep -A4 'autoResourceAllocation' <<<"$REGION_B" | grep -q 'enabled: true'
grep -q 'kind: Deployment' <<<"$REGION_B"
grep -Eq 'kind: "?CouchbaseCluster"?' <<<"$REGION_B"
grep -q 'name: region-b$' <<<"$REGION_B"
# region-b is a single data node, no index/query group, bucket replica 0
grep -A3 'name: data' <<<"$REGION_B" | grep -q 'size: 1'
if grep -q 'name: query' <<<"$REGION_B"; then echo "FAIL: region-b should not have a query group"; exit 1; fi
grep -A8 'name: observer' <<<"$REGION_B" | grep -q 'replicas: 0'

kubectl kustomize "$ROOT/deploy/kind/mock-app" >/dev/null
kubectl kustomize "$ROOT/deploy/kind/observer" >/dev/null

grep -q -- '--conn=couchbase://region-a-srv.region-a.svc' "$ROOT/deploy/kind/observer/deployment.yaml"
grep -q -- '--secondary-conn=couchbase://region-b-srv.region-b.svc' "$ROOT/deploy/kind/observer/deployment.yaml"
grep -q -- '--bucket=observer' "$ROOT/deploy/kind/observer/deployment.yaml"

echo "PASS: kind Helm releases and Kubernetes manifests render"
