#!/usr/bin/env bash
# Region-parameterized Couchbase cluster init for the CNG load-balancer stack.
#
# Differs from deploy/compose/scripts/init-cluster.sh in three ways:
#   1. node lists come from env, so one script initializes either region
#   2. bucket is lbtest with a per-region replica count, not travel-sample
#      (faster, deterministic, and region-b has only one node)
#   3. it writes a region marker document, so a marker GET identifies
#      the serving region
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

# Counts healthy inactiveAdded members needing rebalance, including joins
# partially applied by a CLI error or left pending from an earlier run.
ADDED=0

wait_for_node() {
  echo "Waiting for $1..."
  retry_until "node $1 management API" 300 \
    curl --connect-timeout 2 --max-time 5 -sS -o /dev/null "http://$1:8091"
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

read_cluster_state() {
  curl --connect-timeout 2 --max-time 5 -kfsS -u "${USERNAME}:${PASSWORD}" "${SECURE_URL}/pools/default"
}

# Validate authenticated readback against env, never CLI exit status alone.
# Missing member returns 2, so only a genuinely absent node can be added.
validate_cluster_state() {
  python3 -c '
import json, sys
mode, region, *expected = sys.argv[1:]
def fail(message, code=1):
    print("Cluster state: " + message, file=sys.stderr)
    sys.exit(code)
try:
    state = json.load(sys.stdin)
except (ValueError, TypeError) as error:
    fail("invalid JSON: " + str(error))
if not isinstance(state, dict) or state.get("clusterName") != "region-" + region:
    fail("unexpected clusterName")
nodes = state.get("nodes")
if not isinstance(nodes, list) or any(not isinstance(n, dict) for n in nodes):
    fail("missing nodes array")
hostnames = [n.get("hostname") for n in nodes]
if any(not isinstance(h, str) for h in hostnames) or len(set(hostnames)) != len(hostnames):
    fail("invalid or duplicate hostname")
services = {"data": "kv", "query": "n1ql", "index": "index"}
wanted = {}
for entry in expected:
    name, configured = entry.split("=", 1)
    wanted[name + ".local:8091"] = sorted(services[s] for s in configured.split(","))
if mode == "topology" and set(hostnames) != set(wanted):
    fail("node names/count differ from expected topology")
for hostname, assigned in wanted.items():
    matching = [n for n in nodes if n.get("hostname") == hostname]
    if not matching:
        fail("missing member " + hostname, 2)
    node = matching[0]
    actual = node.get("services")
    if not isinstance(actual, list) or any(not isinstance(s, str) for s in actual) or sorted(actual) != assigned:
        fail("unexpected services for " + hostname)
    if node.get("status") != "healthy":
        fail("member not healthy: " + hostname)
    membership = node.get("clusterMembership")
    allowed = ("active", "inactiveAdded") if mode == "node" else ("active",)
    if membership not in allowed:
        fail("unexpected membership for " + hostname + ": " + str(membership))
    if mode == "node":
        print(membership)
' "$@"
}

primary_is_configured() {
  local state
  state="$(read_cluster_state)" || return $?
  validate_cluster_state primary "$REGION" "${PRIMARY}=${PRIMARY_SERVICES}" <<<"$state"
}

initialize_primary_attempt() {
  local out state
  if state="$(read_cluster_state)"; then
    validate_cluster_state primary "$REGION" "${PRIMARY}=${PRIMARY_SERVICES}" <<<"$state"
    return $?
  fi
  if ! out="$("${CLI}" cluster-init \
      --cluster "${URL}" --cluster-name "region-${REGION}" \
      --cluster-username "${USERNAME}" --cluster-password "${PASSWORD}" \
      --services "${PRIMARY_SERVICES}" --cluster-ramsize "${CLUSTER_RAM_SIZE_MB}" \
      --cluster-index-ramsize "${INDEX_RAM_SIZE_MB}" --index-storage-setting default 2>&1)"; then
    printf '%s\n' "$out" >&2
  fi
  primary_is_configured
}

initialize_primary() {
  local state
  if state="$(read_cluster_state 2>/dev/null)"; then
    validate_cluster_state primary "$REGION" "${PRIMARY}=${PRIMARY_SERVICES}" <<<"$state" || return $?
    echo "Primary already initialized."
    return 0
  fi
  echo "Initializing primary with services: ${PRIMARY_SERVICES}"
  # Couchbase requires an FQDN; URLs keep the env short name.
  retry_until "node-init ${PRIMARY}" 300 "${CLI}" node-init \
    --cluster "${URL}" --node-init-hostname "${PRIMARY}.local" || return $?
  retry_until "cluster-init region-${REGION}" 300 initialize_primary_attempt || return $?
}

wait_for_authenticated_cluster() {
  echo "Waiting for authenticated cluster API..."
  retry_until "authenticated cluster API at ${SECURE_URL}" 300 \
    curl --connect-timeout 2 --max-time 5 -kfsS -u "${USERNAME}:${PASSWORD}" "${SECURE_URL}/pools/default"
}

node_is_clustered() {
  local state
  state="$(read_cluster_state)" || return $?
  validate_cluster_state node "$REGION" "$1=${2:-data}" <<<"$state"
}

add_node_attempt() {
  local node="$1" services="$2" state status out
  state="$(read_cluster_state)" || return $?
  if validate_cluster_state node "$REGION" "${node}=${services}" <<<"$state"; then
    return 0
  else
    status=$?
    [ "$status" -eq 2 ] || return "$status"
  fi
  if ! out="$("${CLI}" server-add \
      --cluster "${SECURE_URL}" --username "${USERNAME}" --password "${PASSWORD}" \
      --server-add "https://${node}.local:18091" \
      --server-add-username "${USERNAME}" --server-add-password "${PASSWORD}" \
      --services "${services}" --no-ssl-verify 2>&1)"; then
    printf '%s\n' "$out" >&2
  fi
  node_is_clustered "$node" "$services"
}

add_node() {
  local node="$1" services="$2" membership
  echo "Converging ${node} (${services})"
  retry_until "server-add ${node}" 300 add_node_attempt "$node" "$services" || return $?
  membership="$(node_is_clustered "$node" "$services")" || return $?
  # retry_until runs attempts in subshells. Count pending rebalance here.
  if [ "$membership" = inactiveAdded ]; then ADDED=$((ADDED+1)); fi
}

verify_cluster_topology() {
  local state node expected=("${PRIMARY}=${PRIMARY_SERVICES}")
  for node in "${DATA_NODES[@]:-}"; do
    if [ -n "$node" ]; then expected+=("${node}=data"); fi
  done
  for node in "${QUERY_NODES[@]:-}"; do
    if [ -n "$node" ]; then expected+=("${node}=index,query"); fi
  done
  state="$(read_cluster_state)" || return $?
  validate_cluster_state topology "$REGION" "${expected[@]}" <<<"$state"
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
  # No "|| true" here: this is the precondition that gives scenarios 2, 3 and
  # 10 their meaning (auto-failover absorbing a single node, refusing a
  # second). Swallowing a failure here would leave the cluster on defaults and
  # make those scenarios measure something else, silently. set -euo pipefail
  # at the top of this script is what we want to fire if the POST fails.
  curl --connect-timeout 2 --max-time 5 -kfsS -u "${USERNAME}:${PASSWORD}" -X POST \
    "${SECURE_URL}/settings/autoFailover" \
    -d enabled=true -d timeout=30 -d maxCount=100 >/dev/null
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

# Python is already supplied by the pinned Couchbase image. Validate the
# top-level status, not a status string inside rows or an error message.
validate_query_response() {
  python3 -c '
import json, sys
try:
    response = json.load(sys.stdin)
except (ValueError, TypeError) as error:
    print("Invalid query JSON: " + str(error), file=sys.stderr)
    sys.exit(1)
if not isinstance(response, dict) or response.get("status") != "success" or response.get("errors"):
    print("Query did not report success without errors", file=sys.stderr)
    sys.exit(1)
if len(sys.argv) > 1:
    rows = response.get("results")
    if rows != [1] or type(rows[0]) is not int:
        print("Query readiness check expected results [1]", file=sys.stderr)
        sys.exit(1)
' "$@"
}

run_query() {
  local out code
  if out="$(curl --connect-timeout 2 --max-time 5 -fsS -u "${USERNAME}:${PASSWORD}" "${QUERY_URL}" \
      --data-urlencode "statement=$1")"; then
    printf '%s\n' "$out"
    if [ "${2:-}" = "ready" ]; then
      validate_query_response ready <<<"$out"
    else
      validate_query_response <<<"$out"
    fi
  else
    code=$?
    printf '%s\n' "$out"
    return "$code"
  fi
}

# retry_until <description> <deadline seconds> <cmd...>: runs <cmd...>
# repeatedly with exponential backoff (2s, capped at 15s) until it succeeds or
# the deadline passes. Used under set -e, so the caller checks the return
# value with "if ! retry_until ..." rather than letting a failure kill the
# script outright. Every attempt's output is captured rather than discarded,
# and the LAST (failing) attempt's output is printed on timeout, so a FATAL
# exit after this carries the actual error instead of nothing at all.
retry_until() {
  local desc="$1" deadline_s="$2"; shift 2
  local start deadline delay=2 out
  start="$(date +%s)"; deadline=$((start + deadline_s))
  until out="$("$@" 2>&1)"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "retry_until: ${desc} did not succeed within ${deadline_s}s" >&2
      echo "retry_until: last attempt's output:" >&2
      echo "$out" >&2
      return 1
    fi
    sleep "$delay"
    if [ "$delay" -lt 15 ]; then delay=$((delay * 2)); fi
  done
}

# wait_for_index_service: the query service can answer "SELECT 1" before the
# index service on the same node is ready to serve DDL, which is exactly the
# race that made "CREATE PRIMARY INDEX" return HTTP 500 on a freshly joined,
# single-node region. QUERY_HOST co-hosts query and index in both layouts.
# This stats preflight is advisory: the SQL online-index readback below is
# the mandatory readiness gate, even if the stats API does not answer.
wait_for_index_service() {
  echo "Waiting for index service on ${QUERY_HOST}..."
  if ! retry_until "index service on ${QUERY_HOST}" 120 \
      curl --connect-timeout 2 --max-time 5 -fsS -o /dev/null -u "${USERNAME}:${PASSWORD}" \
        "http://${QUERY_HOST}:9102/api/v1/stats"; then
    echo "WARNING: index service on ${QUERY_HOST} did not answer within 120s, proceeding anyway" >&2
  fi
}

verify_primary_index_ready() {
  run_query "SELECT RAW 1 FROM system:indexes
    WHERE (keyspace_id = \"${BUCKET}\" OR
      (bucket_id = \"${BUCKET}\" AND scope_id = \"_default\" AND keyspace_id = \"_default\"))
      AND is_primary = true AND state = \"online\" LIMIT 1" ready
}

verify_marker_readable() {
  run_query "SELECT RAW COUNT(*) FROM \`${BUCKET}\` USE KEYS \"region::marker\" WHERE region = \"${REGION}\"" ready
}

create_index_and_marker() {
  echo "Waiting for query service..."
  if ! retry_until "query service readiness" 120 run_query "SELECT 1"; then
    echo "FATAL: query service did not become ready within deadline" >&2
    exit 1
  fi

  wait_for_index_service

  # The index service can still be a few seconds behind even after the wait
  # above answers, so CREATE PRIMARY INDEX gets its own retry loop rather than
  # trusting a single attempt. IF NOT EXISTS also keeps re-runs idempotent.
  echo "Creating primary index on ${BUCKET} (retrying until the index service accepts DDL)..."
  if ! retry_until "CREATE PRIMARY INDEX on ${BUCKET}" 180 \
      run_query "CREATE PRIMARY INDEX IF NOT EXISTS ON \`${BUCKET}\`"; then
    echo "FATAL: could not create primary index on ${BUCKET} for region-${REGION} within deadline" >&2
    exit 1
  fi

  echo "Verifying primary index on ${BUCKET} is online..."
  if ! retry_until "primary index online on ${BUCKET}" 180 verify_primary_index_ready; then
    echo "FATAL: primary index on ${BUCKET} did not become online within deadline" >&2
    exit 1
  fi

  # Marker reads identify the serving region. Retry the write, then verify
  # the expected region is readable before setup can report success.
  echo "Writing region::marker for region-${REGION} (retrying until it succeeds)..."
  if ! retry_until "UPSERT region::marker" 180 \
      run_query "UPSERT INTO \`${BUCKET}\` (KEY, VALUE) VALUES (\"region::marker\", {\"region\":\"${REGION}\"})"; then
    echo "FATAL: could not write region::marker for region-${REGION} within deadline" >&2
    exit 1
  fi

  echo "Verifying region::marker is readable for region-${REGION}..."
  if ! retry_until "verify region::marker readable" 60 verify_marker_readable; then
    echo "FATAL: region::marker for region-${REGION} was written but is not readable back; init must not silently skip the marker" >&2
    exit 1
  fi
  echo "region::marker verified readable for region-${REGION}."
}

all_nodes_ready
initialize_primary
wait_for_authenticated_cluster

for n in "${DATA_NODES[@]:-}"; do if [ -n "$n" ]; then add_node "$n" data; fi; done
for n in "${QUERY_NODES[@]:-}"; do if [ -n "$n" ]; then add_node "$n" index,query; fi; done

if [ "${ADDED}" -gt 0 ]; then
  rebalance
fi

retry_until "region-${REGION} active topology" 300 verify_cluster_topology || exit $?

configure_autofailover
create_bucket
create_index_and_marker

echo "region-${REGION} configured."
