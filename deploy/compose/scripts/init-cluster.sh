#!/usr/bin/env bash
set -euo pipefail

USERNAME="${COUCHBASE_USERNAME:-Administrator}"
PASSWORD="${COUCHBASE_PASSWORD:-password}"
CLUSTER_RAM_SIZE_MB="${COUCHBASE_RAM_SIZE_MB:-4096}"
INDEX_RAM_SIZE_MB="${COUCHBASE_INDEX_RAM_SIZE_MB:-1024}"

CLI="/opt/couchbase/bin/couchbase-cli"
PRIMARY_NODE="cb-data-1.local"
PRIMARY_URL="http://${PRIMARY_NODE}:8091"
PRIMARY_SECURE_URL="https://${PRIMARY_NODE}:18091"

DATA_NODES=("cb-data-2.local" "cb-data-3.local")
INDEX_QUERY_NODES=("cb-index-query-1.local" "cb-index-query-2.local")

wait_for_node() {
  local node="$1"
  local url="http://${node}:8091"

  echo "Waiting for ${node}..."
  until curl -sS -o /dev/null "${url}" >/dev/null 2>&1; do
    sleep 3
  done
}

wait_for_authenticated_cluster() {
  echo "Waiting for authenticated cluster API..."
  until curl -kfsS -u "${USERNAME}:${PASSWORD}" "${PRIMARY_SECURE_URL}/pools/default" >/dev/null 2>&1; do
    sleep 3
  done
}

node_is_clustered() {
  local node="$1"

  curl -kfsS -u "${USERNAME}:${PASSWORD}" "${PRIMARY_SECURE_URL}/pools/default" \
    | grep -q "\"hostname\":\"${node}:8091\""
}

all_nodes_ready() {
  wait_for_node "${PRIMARY_NODE}"

  for node in "${DATA_NODES[@]}" "${INDEX_QUERY_NODES[@]}"; do
    wait_for_node "${node}"
  done
}

initialize_primary() {
  if curl -fsS -u "${USERNAME}:${PASSWORD}" "${PRIMARY_URL}/pools/default" >/dev/null 2>&1; then
    echo "Primary node is already initialized."
    return
  fi

  echo "Initializing primary data node..."
  "${CLI}" node-init \
    --cluster "${PRIMARY_URL}" \
    --node-init-hostname "${PRIMARY_NODE}"

  "${CLI}" cluster-init \
    --cluster "${PRIMARY_URL}" \
    --cluster-name "docker-couchbase" \
    --cluster-username "${USERNAME}" \
    --cluster-password "${PASSWORD}" \
    --services data \
    --cluster-ramsize "${CLUSTER_RAM_SIZE_MB}" \
    --cluster-index-ramsize "${INDEX_RAM_SIZE_MB}" \
    --index-storage-setting default
}

add_node() {
  local node="$1"
  local services="$2"

  if node_is_clustered "${node}"; then
    echo "${node} is already in the cluster."
    return
  fi

  echo "Adding ${node} with services: ${services}"
  "${CLI}" server-add \
    --cluster "${PRIMARY_SECURE_URL}" \
    --username "${USERNAME}" \
    --password "${PASSWORD}" \
    --server-add "https://${node}:18091" \
    --server-add-username "${USERNAME}" \
    --server-add-password "${PASSWORD}" \
    --services "${services}" \
    --no-ssl-verify
}

rebalance_cluster() {
  echo "Rebalancing cluster..."
  "${CLI}" rebalance \
    --cluster "${PRIMARY_SECURE_URL}" \
    --username "${USERNAME}" \
    --password "${PASSWORD}" \
    --no-ssl-verify
}

install_travel_sample_bucket() {
  if "${CLI}" bucket-list \
    --cluster "${PRIMARY_SECURE_URL}" \
    --username "${USERNAME}" \
    --password "${PASSWORD}" \
    --no-ssl-verify \
    | grep -q '^travel-sample$'; then
    echo "travel-sample bucket already exists."
    return
  fi

  echo "Installing travel-sample through Couchbase sample bucket API..."
  curl -kfsS \
    -X POST \
    -u "${USERNAME}:${PASSWORD}" \
    -H "Content-Type: application/json" \
    "${PRIMARY_SECURE_URL}/sampleBuckets/install" \
    -d '["travel-sample"]'
  echo
}

configure_autofailover() {
  # timeout 10s for fast test cycles; maxCount 100 to match Capella's default.
  # maxCount is not a safety knob: auto-failover quorum + replica/durability checks
  # still refuse any failover that would risk split-brain or data loss.
  echo "Configuring auto-failover (timeout=30, maxCount=100)..."
  curl -kfsS -u "${USERNAME}:${PASSWORD}" -X POST \
    "${PRIMARY_SECURE_URL}/settings/autoFailover" \
    -d enabled=true -d timeout=30 -d maxCount=100 >/dev/null || true
}

all_nodes_ready
initialize_primary
wait_for_authenticated_cluster

for node in "${DATA_NODES[@]}"; do
  add_node "${node}" data
done

for node in "${INDEX_QUERY_NODES[@]}"; do
  add_node "${node}" index,query
done

rebalance_cluster
configure_autofailover
install_travel_sample_bucket

echo "Couchbase cluster is configured."
