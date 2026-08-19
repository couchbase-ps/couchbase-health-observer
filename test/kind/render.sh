#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/deploy/kind/couchbase-cluster"

# Register the couchbase-operator repo the chart depends on (absent on fresh checkouts).
helm repo add couchbase-partners https://couchbase-partners.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update couchbase-partners >/dev/null 2>&1 || true
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

kubectl kustomize "$ROOT/deploy/kind/mock-app-b" >/dev/null

APP_B="$(kubectl kustomize "$ROOT/deploy/kind/mock-app-b")"
grep -q 'name: app-b' <<<"$APP_B"
grep -q 'name: mock-app-b' <<<"$APP_B"
grep -q 'connstring: couchbase://region-a-srv.region-a.svc' <<<"$APP_B"

RBAC_TMP="$(mktemp -d)"
trap 'rm -rf "$RBAC_TMP"' EXIT

# The verb set both RBAC copies must grant, and nothing more: get + update on
# configmaps and on apps/deployments, the only calls pkg/actuator makes. Written in
# the block style kubectl kustomize emits (every input below is rendered through
# kustomize, so source formatting cannot affect this). Checking each copy against
# the same literal also pins the two copies to each other.
WANT_RULES='-apiGroups:;-"";resources:;-configmaps;verbs:;-get;-update;-apiGroups:;-apps;resources:;-deployments;verbs:;-get;-update;'

# assert_observer_rbac <label> <expected-binding-namespaces-csv> <yaml>
#
# The observer patches several app namespaces from one central Deployment, so its
# RBAC must be ONE ClusterRole plus a RoleBinding per target namespace, never a
# namespaced Role. The kind stack and the production manifest each carry their own
# copy of that shape and have drifted once already, so both are checked here. Only
# the bound namespaces legitimately differ (production ships default alone), so
# they are a parameter while the verb set is not.
assert_observer_rbac() {
  local label="$1" want_ns="$2" yaml="$3"
  local want_count
  want_count="$(tr ',' '\n' <<<"$want_ns" | grep -c . || true)"

  grep -q '^kind: ClusterRole$' <<<"$yaml" || { echo "FAIL [$label]: no ClusterRole"; exit 1; }
  if grep -q '^kind: Role$' <<<"$yaml"; then echo "FAIL [$label]: namespaced Role still present"; exit 1; fi
  local bindings
  bindings="$(grep -c '^kind: RoleBinding$' <<<"$yaml" || true)"
  [[ "$bindings" == "$want_count" ]] \
    || { echo "FAIL [$label]: expected $want_count RoleBinding(s) ($want_ns), got $bindings"; exit 1; }

  # A multi-document YAML stream defeats grep -A over the whole stream: the -A
  # window of one match can absorb another match's context, so "some binding is
  # correct" reads as "every binding is correct". Split into documents and check
  # each RoleBinding document on its own.
  local docs="$RBAC_TMP/$label"
  mkdir -p "$docs"
  awk -v outdir="$docs" '
    BEGIN { n = 0; doc = "" }
    /^---$/ { if (doc != "") { printf "%s", doc > (outdir "/doc" n ".yaml"); close(outdir "/doc" n ".yaml"); n++ }; doc = ""; next }
    { doc = doc $0 "\n" }
    END { if (doc != "") { printf "%s", doc > (outdir "/doc" n ".yaml"); close(outdir "/doc" n ".yaml"); n++ } }
  ' <<<"$yaml"

  local binding_namespaces=()
  local f meta_ns roleref_block subject_count subjects_block
  for f in "$docs"/doc*.yaml; do
    grep -q '^kind: RoleBinding$' "$f" || continue

    meta_ns="$(awk '/^metadata:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/namespace:/{print $2; exit}' "$f")"
    [[ -n "$meta_ns" ]] || { echo "FAIL [$label]: a RoleBinding is missing metadata.namespace"; exit 1; }

    roleref_block="$(grep -A3 '^roleRef:' "$f")"
    grep -q 'kind: ClusterRole$' <<<"$roleref_block" \
      || { echo "FAIL [$label]: RoleBinding in namespace $meta_ns roleRef.kind is not ClusterRole"; exit 1; }
    grep -q 'name: observer$' <<<"$roleref_block" \
      || { echo "FAIL [$label]: RoleBinding in namespace $meta_ns roleRef.name is not observer"; exit 1; }

    # Indentation-tolerant: kustomize emits subjects at column 0, the raw
    # production manifest keeps them indented under subjects:.
    subject_count="$(grep -c '^[[:space:]]*- kind:' "$f" || true)"
    [[ "$subject_count" == "1" ]] \
      || { echo "FAIL [$label]: RoleBinding in namespace $meta_ns must have exactly one subject, got $subject_count"; exit 1; }

    subjects_block="$(grep -A3 '^subjects:' "$f")"
    grep -q 'kind: ServiceAccount$' <<<"$subjects_block" \
      || { echo "FAIL [$label]: RoleBinding in namespace $meta_ns subject kind is not ServiceAccount"; exit 1; }
    grep -q 'name: observer$' <<<"$subjects_block" \
      || { echo "FAIL [$label]: RoleBinding in namespace $meta_ns subject name is not observer"; exit 1; }
    grep -q 'namespace: default$' <<<"$subjects_block" \
      || { echo "FAIL [$label]: RoleBinding in namespace $meta_ns subject namespace is not default"; exit 1; }

    binding_namespaces+=("$meta_ns")
  done

  local sorted_namespaces
  sorted_namespaces="$(printf '%s\n' "${binding_namespaces[@]}" | sort | tr '\n' ',')"
  [[ "$sorted_namespaces" == "$want_ns" ]] \
    || { echo "FAIL [$label]: RoleBinding namespaces must be exactly $want_ns got: $sorted_namespaces"; exit 1; }

  # Verb set, normalized (comments, indent and spaces dropped) so reformatting is
  # free but an added resource or verb is not.
  local cr="" rules
  for f in "$docs"/doc*.yaml; do
    if grep -q '^kind: ClusterRole$' "$f"; then cr="$f"; break; fi
  done
  [[ -n "$cr" ]] || { echo "FAIL [$label]: no ClusterRole document"; exit 1; }
  rules="$(awk '/^rules:/{f=1;next} f&&/^[a-zA-Z]/{exit} f' "$cr" \
    | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' | tr -d ' ' | tr '\n' ';')"
  [[ "$rules" == "$WANT_RULES" ]] \
    || { echo "FAIL [$label]: ClusterRole rules must be exactly $WANT_RULES got: $rules"; exit 1; }
}

# The kind stack binds both app namespaces. The production manifest that
# docs/DEPLOYMENT.md points operators at ships the default binding only, so it gets
# the same shape check with its own expected binding list. It is a plain
# multi-document file, so wrap it in a throwaway kustomization: both inputs then
# reach the assertions in the same rendered style.
PROD_KUSTOMIZE="$RBAC_TMP/prod-kustomize"
mkdir -p "$PROD_KUSTOMIZE"
cp "$ROOT/deploy/k8s/observer.yaml" "$PROD_KUSTOMIZE/observer.yaml"
cat >"$PROD_KUSTOMIZE/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - observer.yaml
YAML

assert_observer_rbac kind 'app-b,default,' "$(kubectl kustomize "$ROOT/deploy/kind/observer")"
assert_observer_rbac prod 'default,' "$(kubectl kustomize "$PROD_KUSTOMIZE")"

# The observer must run with namespace-qualified targets covering both namespaces.
grep -q -- '--configmap=cb-conn,app-b/cb-conn' "$ROOT/deploy/kind/observer/deployment.yaml"
grep -q -- '--deployments=mock-app,app-b/mock-app-b' "$ROOT/deploy/kind/observer/deployment.yaml"

echo "PASS: kind Helm releases and Kubernetes manifests render"
