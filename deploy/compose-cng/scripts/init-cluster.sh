#!/usr/bin/env bash
# Region-parameterized Couchbase cluster init for the CNG load-balancer stack.
#
# Differs from deploy/compose/scripts/init-cluster.sh in three ways:
#   1. node lists come from env, so one script initializes either region
#   2. bucket is lbtest with a per-region replica count, not travel-sample
#      (faster, deterministic, and region-b has only one node)
#   3. it writes a region marker document, so the harness can tell which
#      cluster served each operation
set -euo pipefail

USERNAME="${COUCHBASE_USERNAME:-Administrator}"
PASSWORD="${COUCHBASE_PASSWORD:-password}"
CLUSTER_RAM_SIZE_MB="${COUCHBASE_RAM_SIZE_MB:-2048}"
INDEX_RAM_SIZE_MB="${COUCHBASE_INDEX_RAM_SIZE_MB:-512}"

REGION="${REGION:?REGION must be set (a or b)}"
PRIMARY="${CB_PRIMARY:?CB_PRIMARY must be set}"
BUCKET="${CB_BUCKET:-lbtest}"
REPLICAS="${CB_BUCKET_REPLICAS:-1}"
PRIMARY_SERVICES="${CB_PRIMARY_SERVICES:-data}"

# Space separated, either may be empty (region-b has neither).
read -r -a DATA_NODES <<<"${CB_DATA_NODES:-}"
read -r -a QUERY_NODES <<<"${CB_QUERY_NODES:-}"

CLI="/opt/couchbase/bin/couchbase-cli"
URL="http://${PRIMARY}:8091"
SECURE_URL="https://${PRIMARY}:18091"

# The query service does not necessarily run on PRIMARY: region-a's primary
# runs "data" only, and query lives on CB_QUERY_NODES (cb-a-iq-1/2). Sending
# N1QL to a node without the query service means the port never opens, so the
# "waiting for query service" loop below would retry forever. Route to the
# first query node when one is configured, else fall back to PRIMARY (region-b,
# whose single node runs "data,index,query").
QUERY_HOST="${PRIMARY}"
if [ "${#QUERY_NODES[@]}" -gt 0 ] && [ -n "${QUERY_NODES[0]:-}" ]; then
  QUERY_HOST="${QUERY_NODES[0]}"
fi
QUERY_URL="http://${QUERY_HOST}:8093/query/service"

# Counts nodes actually added this run, so rebalance only fires when there is
# something to rebalance. Region-b passes empty node lists, so this stays 0
# there and the ${#arr[@]:-0} array-length-defaulting bug (invalid bash, and
# never exercised except on the region-b empty-list path) is avoided entirely.
ADDED=0

wait_for_node() {
  echo "Waiting for $1..."
  until curl -sS -o /dev/null "http://$1:8091" >/dev/null 2>&1; do sleep 3; done
}

all_nodes_ready() {
  wait_for_node "${PRIMARY}"
  # "if ...; then" rather than "[ -n \"\$n\" ] && wait_for_node \"\$n\"": under
  # set -e, a bare "test && cmd" statement whose test is false makes the whole
  # statement's exit status 1, which kills the script right there. Region-b
  # passes empty CB_DATA_NODES/CB_QUERY_NODES, so "${DATA_NODES[@]:-}" still
  # yields one empty placeholder element and the "&&" form died on it before
  # ever reaching initialize_primary. This is a second, separate empty-list
  # bug from the ${#DATA_NODES[@]:-0} one already fixed below.
  for n in "${DATA_NODES[@]:-}" "${QUERY_NODES[@]:-}"; do
    if [ -n "$n" ]; then wait_for_node "$n"; fi
  done
}

initialize_primary() {
  if curl -fsS -u "${USERNAME}:${PASSWORD}" "${URL}/pools/default" >/dev/null 2>&1; then
    echo "Primary already initialized."
    return
  fi
  echo "Initializing primary with services: ${PRIMARY_SERVICES}"
  # Couchbase 8.0.1 refuses a bare, dot-less --node-init-hostname ("Short
  # names are not allowed"). ${PRIMARY} itself stays exactly the env-contract
  # value (no dot, used unchanged for the API URL above and for the
  # observer's connection string); only the value announced to Couchbase
  # gets the ".local" suffix, matching the compose hostname/alias below and
  # the same convention deploy/compose/scripts/init-cluster.sh already uses.
  "${CLI}" node-init --cluster "${URL}" --node-init-hostname "${PRIMARY}.local"
  "${CLI}" cluster-init \
    --cluster "${URL}" \
    --cluster-name "region-${REGION}" \
    --cluster-username "${USERNAME}" \
    --cluster-password "${PASSWORD}" \
    --services "${PRIMARY_SERVICES}" \
    --cluster-ramsize "${CLUSTER_RAM_SIZE_MB}" \
    --cluster-index-ramsize "${INDEX_RAM_SIZE_MB}" \
    --index-storage-setting default
}

wait_for_authenticated_cluster() {
  echo "Waiting for authenticated cluster API..."
  until curl -kfsS -u "${USERNAME}:${PASSWORD}" "${SECURE_URL}/pools/default" >/dev/null 2>&1; do
    sleep 3
  done
}

node_is_clustered() {
  # Nodes are registered under their ".local" FQDN (see add_node), so that is
  # what pools/default reports back.
  curl -kfsS -u "${USERNAME}:${PASSWORD}" "${SECURE_URL}/pools/default" \
    | grep -q "\"hostname\":\"$1.local:8091\""
}

add_node() {
  local node="$1" services="$2"
  if node_is_clustered "${node}"; then
    echo "${node} already in cluster."
    return
  fi
  echo "Adding ${node} (${services})"
  # ".local" suffix: same short-name restriction as node-init, and the joining
  # node's self-signed cert SAN is generated from its own compose hostname
  # (also ".local", see docker-compose.region-*.yml), so the two must match
  # for the TLS handshake during join to pass hostname verification.
  "${CLI}" server-add \
    --cluster "${SECURE_URL}" --username "${USERNAME}" --password "${PASSWORD}" \
    --server-add "https://${node}.local:18091" \
    --server-add-username "${USERNAME}" --server-add-password "${PASSWORD}" \
    --services "${services}" --no-ssl-verify
  ADDED=$((ADDED+1))
}

rebalance() {
  echo "Rebalancing..."
  "${CLI}" rebalance --cluster "${SECURE_URL}" \
    --username "${USERNAME}" --password "${PASSWORD}" --no-ssl-verify
}

configure_autofailover() {
  # timeout 30 and maxCount 100 deliberately match deploy/compose. maxCount is
  # not the discriminator: on 3 data nodes with replica 1, auto-failover quorum
  # and replica checks refuse the second failover regardless of the count, which
  # is exactly what scenario 3 relies on. maxCount 100 also matches Capella.
  echo "Configuring auto-failover (timeout=30, maxCount=100)..."
  curl -kfsS -u "${USERNAME}:${PASSWORD}" -X POST \
    "${SECURE_URL}/settings/autoFailover" \
    -d enabled=true -d timeout=30 -d maxCount=100 >/dev/null || true
}

create_bucket() {
  if "${CLI}" bucket-list --cluster "${SECURE_URL}" \
      --username "${USERNAME}" --password "${PASSWORD}" --no-ssl-verify \
      | grep -q "^${BUCKET}$"; then
    echo "Bucket ${BUCKET} already exists."
    return
  fi
  echo "Creating bucket ${BUCKET} (replicas=${REPLICAS})"
  "${CLI}" bucket-create --cluster "${SECURE_URL}" \
    --username "${USERNAME}" --password "${PASSWORD}" --no-ssl-verify \
    --bucket "${BUCKET}" --bucket-type couchbase \
    --bucket-ramsize 512 --bucket-replica "${REPLICAS}" --wait
}

run_query() {
  curl -fsS -u "${USERNAME}:${PASSWORD}" "${QUERY_URL}" \
    --data-urlencode "statement=$1"
  echo
}

create_index_and_marker() {
  echo "Waiting for query service..."
  until curl -fsS -o /dev/null -u "${USERNAME}:${PASSWORD}" "${QUERY_URL}" \
      --data-urlencode "statement=SELECT 1" >/dev/null 2>&1; do
    sleep 3
  done
  # IF NOT EXISTS keeps re-runs idempotent.
  run_query "CREATE PRIMARY INDEX IF NOT EXISTS ON \`${BUCKET}\`"
  # The region marker is how the harness attributes each operation to a
  # cluster. Without it "did it switch" is guesswork.
  run_query "UPSERT INTO \`${BUCKET}\` (KEY, VALUE) VALUES (\"region::marker\", {\"region\":\"${REGION}\"})"
}

all_nodes_ready
initialize_primary
wait_for_authenticated_cluster

for n in "${DATA_NODES[@]:-}"; do if [ -n "$n" ]; then add_node "$n" data; fi; done
for n in "${QUERY_NODES[@]:-}"; do if [ -n "$n" ]; then add_node "$n" index,query; fi; done

if [ "${ADDED}" -gt 0 ]; then
  rebalance
fi

configure_autofailover
create_bucket
create_index_and_marker

echo "region-${REGION} configured."
