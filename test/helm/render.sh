#!/usr/bin/env bash
# Renders the observer chart under several value sets and asserts on the output.
# No cluster needed: helm lint + helm template only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/charts/couchbase-health-observer"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -q -- "$2" <<<"$1" || fail "${3:-missing: $2}"; }
hasnot() { grep -q -- "$2" <<<"$1" && fail "${3:-unexpected: $2}"; return 0; }

helm lint "$CHART" >/dev/null || fail "helm lint"

DEFAULT="$(helm template observer "$CHART" --namespace default)"

# Step 2: workloads.
has "$DEFAULT" 'kind: Deployment'
has "$DEFAULT" 'kind: Service'
has "$DEFAULT" 'kind: ServiceAccount'
has "$DEFAULT" 'image: ghcr.io/couchbase-ps/couchbase-health-observer:0.5.0' "image tag must fall back to appVersion"
hasnot "$DEFAULT" ':latest' "never ship the latest tag"
has "$DEFAULT" '--actuators=k8s'
has "$DEFAULT" 'path: /healthz'
has "$DEFAULT" 'path: /readyz'
hasnot "$DEFAULT" 'path: /health/couchbase' "probes must never point at /health/couchbase"
has "$DEFAULT" 'containerPort: 8080'
has "$DEFAULT" 'prometheus.io/scrape: "true"'
[ "$(grep -c 'prometheus.io/scrape' <<<"$DEFAULT")" -eq 2 ] || fail "scrape annotation on both Service and pod template"
has "$DEFAULT" 'name: observer-couchbase-health-observer' "default naming is <release>-<chart>"

PINNED="$(helm template observer "$CHART" --namespace default --set image.tag=dev)"
has "$PINNED" 'image: ghcr.io/couchbase-ps/couchbase-health-observer:dev' "explicit tag must win over appVersion"

OVERRIDE="$(helm template obs "$CHART" --namespace default --set fullnameOverride=observer)"
has "$OVERRIDE" 'name: observer$' "fullnameOverride must rename every object"
hasnot "$OVERRIDE" 'name: obs-couchbase-health-observer' "fullnameOverride must leave no default name"

EXTRA="$(helm template observer "$CHART" --namespace default --set 'extraArgs={--gocb-verbose}')"
has "$EXTRA" '--gocb-verbose'
[ "$(grep -n -- '--gocb-verbose' <<<"$EXTRA" | cut -d: -f1)" -gt "$(grep -n -- '--actuators' <<<"$EXTRA" | cut -d: -f1)" ] \
  || fail "extraArgs must come after the generated args"

# Step 3: credentials live in a Secret, never in the args.
has "$DEFAULT" 'kind: Secret'
has "$DEFAULT" 'name: observer-couchbase-health-observer-credentials'
has "$DEFAULT" '--user=$(CB_USER)'
has "$DEFAULT" '--pass=$(CB_PASS)'
hasnot "$DEFAULT" '--pass=password' "the password must never reach the args"
has "$DEFAULT" 'name: CB_USER'
has "$DEFAULT" 'name: CB_PASS'
has "$DEFAULT" 'secretKeyRef'

EXISTING="$(helm template observer "$CHART" --namespace default \
  --set couchbase.existingSecret=my-cb-creds --set couchbase.passwordKey=cb-password)"
hasnot "$EXISTING" 'kind: Secret' "existingSecret must render no Secret"
has "$EXISTING" 'name: my-cb-creds'
has "$EXISTING" 'key: cb-password'

WH="$(helm template observer "$CHART" --namespace default \
  --set 'actuators=k8s\,webhook' \
  --set webhook.url=https://ci.example.com/trigger \
  --set webhook.username=observer --set webhook.password=s3cret \
  --set 'webhook.headers={X-Source: observer}')"
has "$WH" '--webhook-url=https://ci.example.com/trigger'
has "$WH" 'name: WEBHOOK_USER'
has "$WH" 'name: WEBHOOK_PASS'
grep -Eq '^ *- --.*s3cret' <<<"$WH" && fail "the webhook password must never reach the args"
has "$WH" '--webhook-header=X-Source: observer'

hasnot "$DEFAULT" '--webhook' "webhook args must not render without the webhook actuator"

# Step 4: TLS certificate mount.
hasnot "$DEFAULT" '--tls-cert-path' "no cert path without a CA certificate"

TLS="$(helm template observer "$CHART" --namespace default \
  --set couchbase.connString=couchbases://cb.example.com \
  --set tls.caCert='-----BEGIN CERTIFICATE-----')"
has "$TLS" 'name: observer-couchbase-health-observer-ca'
has "$TLS" '--tls-cert-path=/etc/observer/tls/ca.pem'
has "$TLS" 'mountPath: /etc/observer/tls'
has "$TLS" 'readOnly: true'

TLS_EXISTING="$(helm template observer "$CHART" --namespace default \
  --set tls.existingCaSecret=cb-ca --set tls.caSecretKey=root.pem)"
has "$TLS_EXISTING" 'secretName: cb-ca'
has "$TLS_EXISTING" '--tls-cert-path=/etc/observer/tls/root.pem'
hasnot "$TLS_EXISTING" 'observer-couchbase-health-observer-ca' "existingCaSecret must render no CA Secret"

SKIP="$(helm template observer "$CHART" --namespace default --set tls.skipVerify=true)"
has "$SKIP" '--tls-skip-verify'

WH_TLS="$(helm template observer "$CHART" --namespace default \
  --set 'actuators=k8s\,webhook' --set webhook.url=https://ci.example.com/trigger \
  --set webhook.caCert='-----BEGIN CERTIFICATE-----')"
has "$WH_TLS" '--webhook-ca-cert=/etc/observer/webhook-ca/ca.pem'
has "$WH_TLS" 'mountPath: /etc/observer/webhook-ca'

# Step 5: RBAC, with the namespace set derived from the targets.
has "$DEFAULT" 'kind: ClusterRole'
has "$DEFAULT" 'kind: RoleBinding'
hasnot "$DEFAULT" 'kind: ClusterRoleBinding' "a ClusterRoleBinding would grant every namespace"
[ "$(grep -c 'kind: RoleBinding' <<<"$DEFAULT")" -eq 1 ] || fail "one RoleBinding for one target namespace"
grep -A14 'kind: ClusterRole$' <<<"$DEFAULT" | grep -q 'configmaps' || fail "ClusterRole must cover configmaps"
grep -Eq 'verbs: \["get", "update"\]|- get' <<<"$DEFAULT" || fail "ClusterRole verbs"
hasnot "$DEFAULT" '- delete' "the observer never deletes"
hasnot "$DEFAULT" '- list' "the observer never lists"

MULTI="$(helm template observer "$CHART" --namespace default \
  --set 'targets.configmaps=cb-conn\,app-b/cb-conn' \
  --set 'targets.deployments=mock-app\,app-b/mock-app-b')"
[ "$(grep -c 'kind: RoleBinding' <<<"$MULTI")" -eq 2 ] || fail "two target namespaces, two RoleBindings"
has "$MULTI" 'namespace: app-b'

FIXED="$(helm template observer "$CHART" --namespace default \
  --set 'rbac.namespaces={team-a,team-b,team-c}')"
[ "$(grep -c 'kind: RoleBinding' <<<"$FIXED")" -eq 3 ] || fail "rbac.namespaces must override the derived set"

OBSERVE="$(helm template observer "$CHART" --namespace default --set actuators='')"
hasnot "$OBSERVE" 'kind: ClusterRole' "observe only needs no RBAC"
hasnot "$OBSERVE" 'kind: RoleBinding' "observe only needs no RBAC"
hasnot "$OBSERVE" '--configmap' "observe only patches nothing"
hasnot "$OBSERVE" '--actuators' "observe only passes no actuator flag"

# Step 6: monitoring objects, both off by default because they need CRDs.
hasnot "$DEFAULT" 'kind: PrometheusRule' "PrometheusRule needs a CRD, keep it opt in"
hasnot "$DEFAULT" 'kind: ServiceMonitor' "ServiceMonitor needs a CRD, keep it opt in"

MON="$(helm template observer "$CHART" --namespace default \
  --set monitoring.prometheusRule.enabled=true \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.prometheusRule.job=cb-observer)"
has "$MON" 'kind: PrometheusRule'
has "$MON" 'kind: ServiceMonitor'
for alert in ObserverAbsent ObserverLoopStalled CouchbaseSustainedDown ObserverActuationErrors ObserverSwitchHeldSecondaryDown; do
  has "$MON" "alert: $alert"
done
has "$MON" 'up{job="cb-observer"} == 0'
has "$MON" 'port: http'

echo "PASS: chart lints and renders"
