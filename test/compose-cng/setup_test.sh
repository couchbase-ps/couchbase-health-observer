#!/usr/bin/env bash
# Offline regressions for setup responses and rendered local port exposure.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export REGION=a CB_PRIMARY=cb-a-data-1
# Load real setup functions without running cluster initialization.
sed '/^all_nodes_ready$/,$d' "${INIT_SCRIPT:-$REPO/deploy/compose-cng/scripts/init-cluster.sh}" >"$WORK/init-functions.sh"
source "$WORK/init-functions.sh"

curl() { printf '%s\n' "$RESPONSE"; return "${CURL_STATUS:-0}"; }
query_status() {
  local status=0
  run_query 'SELECT 1' >"$WORK/output" 2>"$WORK/error" || status=$?
  [ "$status" = "$1" ] || { echo "expected query status $1, got $status"; return 1; }
}
transport_failure() {
  RESPONSE='curl: (22) HTTP 500' CURL_STATUS=22
  query_status 22
}
sql_failure() {
  RESPONSE='{"requestID":"test","status":"errors","errors":[{"code":5000,"msg":"index service unavailable"}],"results":[]}' CURL_STATUS=0
  query_status 1 || return 1
  grep -q 'index service unavailable' "$WORK/output"
}
nested_success() {
  RESPONSE='{"status":"errors","results":[{"status":"success"}],"errors":[{"code":5000,"msg":"DDL failed"}]}' CURL_STATUS=0
  query_status 1
}
invalid_response() {
  CURL_STATUS=0
  for RESPONSE in 'not JSON' '{"results":[1]}' '{"status":"success","errors":[{"code":5000}]}' '[]'; do
    query_status 1 || return 1
  done
}
valid_response() {
  RESPONSE='{"requestID":"test","status":"success","results":[1],"metrics":{"resultCount":1}}' CURL_STATUS=0
  query_status 0 || return 1
  [ "$(cat "$WORK/output")" = "$RESPONSE" ]
}
transient_retry() {
  echo 0 >"$WORK/attempts"
  curl() {
    local n
    n="$(cat "$WORK/attempts")"; n=$((n+1)); echo "$n" >"$WORK/attempts"
    if [ "$n" -eq 1 ]; then
      echo '{"status":"errors","errors":[{"code":5000,"msg":"index warming up"}]}'
    else
      echo '{"status":"success","results":[]}'
    fi
  }
  sleep() { :; }
  retry_until 'transient SQL error' 10 run_query 'CREATE PRIMARY INDEX' || return 1
  [ "$(cat "$WORK/attempts")" -eq 2 ]
}
persistent_failure() {
  RESPONSE='{"status":"errors","errors":[{"code":5000,"msg":"persistent index failure"}]}' CURL_STATUS=0
  if retry_until 'persistent SQL error' 0 run_query 'CREATE PRIMARY INDEX' >"$WORK/output" 2>&1; then
    echo 'persistent SQL error accepted'; return 1
  fi
  grep -q 'persistent index failure' "$WORK/output"
}
marker_readiness() {
  CURL_STATUS=0
  RESPONSE='{"status":"errors","results":[1],"errors":[{"code":5000,"msg":"marker unavailable"}]}'
  if verify_marker_readable >"$WORK/output" 2>&1; then echo 'failed marker query accepted'; return 1; fi
  RESPONSE='{"status":"success","results":[0]}'
  if verify_marker_readable >"$WORK/output" 2>&1; then echo 'missing marker accepted'; return 1; fi
  RESPONSE='{"status":"success","results":[1]}'
  verify_marker_readable >"$WORK/output" 2>&1
}
index_readiness() {
  curl() {
    case "$*" in
      *'system:indexes'*'is_primary'*'online'*) printf '%s\n' "$RESPONSE" ;;
      *) echo 'index readiness must inspect online primary index' >&2; return 1 ;;
    esac
  }
  RESPONSE='{"status":"success","results":[0]}'
  if verify_primary_index_ready >"$WORK/output" 2>&1; then echo 'missing index accepted'; return 1; fi
  RESPONSE='{"status":"success","results":[1]}'
  verify_primary_index_ready >"$WORK/output" 2>&1
}
setup_verifies_readiness() {
  echo 0 >"$WORK/index-checks"; echo 0 >"$WORK/marker-checks"
  curl() {
    local file n
    case "$*" in
      *system:indexes*) file="$WORK/index-checks" ;;
      *'SELECT RAW COUNT('*'region::marker'*) file="$WORK/marker-checks" ;;
      *) echo '{"status":"success","results":[]}'; return 0 ;;
    esac
    n="$(cat "$file")"; n=$((n+1)); echo "$n" >"$file"
    if [ "$n" -eq 1 ]; then
      echo '{"status":"success","results":[0]}'
    else
      echo '{"status":"success","results":[1]}'
    fi
  }
  sleep() { :; }
  create_index_and_marker >"$WORK/output" 2>&1 || return 1
  [ "$(cat "$WORK/index-checks")" -eq 2 ] || { echo 'setup did not await online primary index'; return 1; }
  [ "$(cat "$WORK/marker-checks")" -eq 2 ] || { echo 'setup did not await matching region marker'; return 1; }
}
# Nonresponding HTTP double only terminates with both real timeout flags.
# Supervisor prevents a regression hanging the offline suite.
bounded_init_request() {
  cat >"$WORK/blocked-query.sh" <<'SH'
source "$1"
curl() {
  case " $* " in
    *' --connect-timeout 2 --max-time 5 '*) command sleep 0.1; return 28 ;;
    *) command sleep 30 ;;
  esac
}
retry_until 'nonresponding query' 0 run_query 'SELECT 1'
SH
  python3 - "$WORK/blocked-query.sh" "$WORK/init-functions.sh" <<'PYTIMEOUT'
import subprocess, sys
try:
    result = subprocess.run(['bash', sys.argv[1], sys.argv[2]], capture_output=True, text=True, timeout=2)
except subprocess.TimeoutExpired:
    raise SystemExit('retry_until remained blocked on an unbounded HTTP request')
assert result.returncode == 1, result
assert 'nonresponding query did not succeed within 0s' in result.stderr, result.stderr
PYTIMEOUT
}
readiness_deadlines() {
  local fn label budget status expected_status="${2:-1}"
  curl() {
    case " $* " in
      *' --connect-timeout 2 --max-time 5 '*) ;;
      *) echo 'readiness HTTP request lacks timeout bounds' >&2; exit 98 ;;
    esac
    echo 'curl: (28) request timed out' >&2; return 28
  }
  date() { cat "$WORK/clock"; }
  sleep() {
    local now; now="$(cat "$WORK/clock")"; now=$((now+100)); echo "$now" >"$WORK/clock"
    [ "$now" -lt 2000 ] || exit 99
  }
  for fn in "$1"; do
    case "$fn" in
      wait_for_node) label=cb-a-data-1; budget=300 ;;
      wait_for_authenticated_cluster) label='authenticated cluster API'; budget=300 ;;
      wait_for_index_service) label='index service'; budget=120 ;;
    esac
    echo 1000 >"$WORK/clock"; status=0
    ( "$fn" cb-a-data-1 ) >"$WORK/output" 2>&1 || status=$?
    [ "$status" -eq "$expected_status" ] || { echo "$fn missed deadline result $expected_status (status=$status)"; return 1; }
    grep -q "$label" "$WORK/output" && grep -q "within ${budget}s" "$WORK/output" || return 1
  done
}
node_deadline() { readiness_deadlines wait_for_node; }
auth_deadline() { readiness_deadlines wait_for_authenticated_cluster; }
index_deadline() {
  readiness_deadlines wait_for_index_service 0 || return 1
  grep -q 'WARNING.*proceeding anyway' "$WORK/output"
}
readiness_success() {
  curl() {
    case " $* " in
      *' --connect-timeout 2 --max-time 5 '*) return 0 ;;
      *) echo 'readiness HTTP request lacks timeout bounds' >&2; return 99 ;;
    esac
  }
  wait_for_node cb-a-data-1 && wait_for_authenticated_cluster && wait_for_index_service
}
all_init_requests_bounded() {
  CLI=true
  curl() {
    case " $* " in
      *' --connect-timeout 2 --max-time 5 '*) ;;
      *) echo 'init HTTP request lacks timeout bounds' >&2; return 99 ;;
    esac
    case "$*" in
      *'/pools/default'*) echo '{"clusterName":"region-a","nodes":[{"hostname":"cb-a-data-1.local:8091","status":"healthy","clusterMembership":"active","services":["kv"]},{"hostname":"cb-a-data-2.local:8091","status":"healthy","clusterMembership":"active","services":["kv"]}]}' ;;
      *) echo '{"status":"success","results":[1]}' ;;
    esac
  }
  initialize_primary && node_is_clustered cb-a-data-2 && configure_autofailover && run_query 'SELECT 1'
}
network_create_failure() {
  docker() { if [ "$2" = inspect ]; then return 1; else return 23; fi; }
  export -f docker
  local status=0
  bash "$REPO/deploy/compose-cng/net.sh" up >"$WORK/output" 2>&1 || status=$?
  [ "$status" -eq 23 ] || { cat "$WORK/output"; echo "network create failure lost status 23 (got=$status)"; return 1; }
  ! grep -q 'created' "$WORK/output"
}
network_existing_subnet() {
  docker() { echo "bridge $NETWORK_SUBNET"; }
  export -f docker
  export NETWORK_SUBNET=10.1.0.0/16
  local status=0
  bash "$REPO/deploy/compose-cng/net.sh" up >"$WORK/output" 2>&1 || status=$?
  [ "$status" -ne 0 ] || { echo 'accepted existing network with wrong subnet'; return 1; }
  grep -q '172.28.0.0/16' "$WORK/output" || return 1
  NETWORK_SUBNET=172.28.0.0/16
  bash "$REPO/deploy/compose-cng/net.sh" up >"$WORK/output" 2>&1
}
probe_budget() {
  local dir="$REPO/deploy/compose-cng"
  docker compose --env-file "$dir/env/region-a.env" -f "$dir/docker-compose.base.yml" \
    -f "$dir/docker-compose.region-a.yml" config --format json >"$WORK/budget.json" || return 1
  python3 - "$WORK/budget.json" "$dir/envoy/envoy.yaml" <<'PYTHON'
import json, pathlib, re, sys
args = json.loads(pathlib.Path(sys.argv[1]).read_text())['services']['observer']['command']
probe = next((arg.split('=', 1)[1] for arg in args if arg.startswith('--probe-timeout=')), None)
if probe is None:
    raise SystemExit('observer requires explicit per-ping timeout for complete probe budget')
unit = re.fullmatch(r'([0-9.]+)(ms|s)', probe)
if not unit:
    raise SystemExit(f'unsupported test timeout format: {probe}')
budget = 2 * float(unit[1]) / (1000 if unit[2] == 'ms' else 1)
timeout = re.search(r'^\s+(?:-\s+)?timeout:\s+([0-9.]+)s\s*$', pathlib.Path(sys.argv[2]).read_text(), re.M)
if timeout is None or float(timeout[1]) <= budget:
    raise SystemExit(f'Envoy timeout must exceed both sequential ping budgets ({budget}s)')
print(f'Envoy {timeout[1]}s exceeds complete Observer {budget:g}s probe budget')
PYTHON
}
local_ports() {
  local dir="$REPO/deploy/compose-cng" region
  for region in a b; do
    docker compose --env-file "$dir/env/region-$region.env" -f "$dir/docker-compose.base.yml" \
      -f "$dir/docker-compose.region-$region.yml" config --format json >"$WORK/region-$region.json" || return 1
  done
  docker compose -f "$dir/envoy/docker-compose.yml" config --format json >"$WORK/envoy.json" || return 1
  python3 - "$WORK" <<'PY'
import json, pathlib, sys
for path in (pathlib.Path(sys.argv[1]) / name for name in ('region-a.json', 'region-b.json', 'envoy.json')):
    for name, service in json.loads(path.read_text())['services'].items():
        for port in service.get('ports', []):
            if port.get('host_ip') != '127.0.0.1':
                raise SystemExit(f'{path.stem}/{name} port {port["published"]} is not local-only')
print('all rendered host publications use 127.0.0.1')
PY
}

# Model real CLI side effects through files: retry_until uses command substitution.
startup_fixture() {
  CLI=startup_cli
  echo 0 >"$WORK/clock"; echo 0 >"$WORK/node-init-count"; echo 0 >"$WORK/cluster-init-count"; echo 0 >"$WORK/server-add-count"; echo 0 >"$WORK/rebalance-count"
  rm -f "$WORK/cluster.json"
  date() { cat "$WORK/clock"; }
  sleep() { local n; n="$(cat "$WORK/clock")"; echo $((n+100)) >"$WORK/clock"; }
  curl() {
    case "$*" in
      *'/pools/default'*) [ -f "$WORK/cluster.json" ] || return 22; cat "$WORK/cluster.json" ;;
      *) return 0 ;;
    esac
  }
  startup_cli() {
    local n file="$WORK/$1-count"
    n="$(cat "$file")"; n=$((n+1)); echo "$n" >"$file"
    case "$1" in
      node-init)
        if [ "${NODE_FAIL:-0}" -eq 1 ] || { [ "${NODE_TRANSIENT:-0}" -eq 1 ] && [ "$n" -eq 1 ]; }; then
          echo 'ERROR: node init temporary failure' >&2; return 1
        fi ;;
      cluster-init)
        if [ "${CLUSTER_FAIL:-0}" -eq 1 ] || { [ "${CLUSTER_TRANSIENT:-0}" -eq 1 ] && [ "$n" -eq 1 ]; }; then
          echo 'ERROR: Internal server error, please retry your request.' >&2; return 1
        fi
        if [ "${CLUSTER_NO_APPLY:-0}" -eq 1 ]; then return 0; fi
        primary_state
        if [ "${CLUSTER_PARTIAL:-0}" -eq 1 ]; then echo 'ERROR: join completion failed after apply' >&2; return 1; fi ;;
      rebalance) joined_state active ;;
      server-add)
        if [ "${JOIN_FAIL:-0}" -eq 1 ] || { [ "${JOIN_TRANSIENT:-0}" -eq 1 ] && [ "$n" -eq 1 ]; }; then
          echo 'ERROR: Join completion call failed.' >&2; return 1
        fi
        if [ "${JOIN_NO_APPLY:-0}" -eq 1 ]; then return 0; fi
        joined_state inactiveAdded
        if [ "${JOIN_WRONG_APPLY:-0}" -eq 1 ]; then
          sed 's/"inactiveAdded"/"inactiveFailed"/g' "$WORK/cluster.json" >"$WORK/wrong.json"
          mv "$WORK/wrong.json" "$WORK/cluster.json"
        fi
        if [ "${JOIN_PARTIAL:-0}" -eq 1 ]; then echo 'ERROR: Join completion call failed.' >&2; return 1; fi ;;
    esac
  }
}
primary_state() {
  cat >"$WORK/cluster.json" <<'JSON'
{"clusterName":"region-a","nodes":[{"hostname":"cb-a-data-1.local:8091","status":"healthy","clusterMembership":"active","services":["kv"]}]}
JSON
}
joined_state() {
  cat >"$WORK/cluster.json" <<JSON
{"clusterName":"region-a","nodes":[{"hostname":"cb-a-data-1.local:8091","status":"healthy","clusterMembership":"active","services":["kv"]},{"hostname":"cb-a-data-2.local:8091","status":"healthy","clusterMembership":"$1","services":["kv"]}]}
JSON
}
primary_node_init_failure() {
  startup_fixture; NODE_FAIL=1
  if initialize_primary >"$WORK/output" 2>&1; then echo 'failed node-init accepted'; return 1; fi
  [ "$(cat "$WORK/cluster-init-count")" -eq 0 ] || { echo 'cluster-init ran after failed node-init'; return 1; }
  grep -q 'node init temporary failure' "$WORK/output"
}
primary_transient_retry() {
  startup_fixture; NODE_TRANSIENT=1 CLUSTER_TRANSIENT=1
  initialize_primary >"$WORK/output" 2>&1 || { cat "$WORK/output"; return 1; }
  [ "$(cat "$WORK/node-init-count")" -eq 2 ] && [ "$(cat "$WORK/cluster-init-count")" -eq 2 ]
}
primary_partial_readback() {
  startup_fixture; CLUSTER_PARTIAL=1
  initialize_primary >"$WORK/output" 2>&1 || { cat "$WORK/output"; return 1; }
  [ "$(cat "$WORK/cluster-init-count")" -eq 1 ]
}
primary_wrong_configuration() {
  startup_fixture; primary_state
  local change
  for change in clusterName hostname services status clusterMembership; do
    primary_state
    python3 - "$WORK/cluster.json" "$change" <<'JSONEDIT'
import json, sys
p, key = sys.argv[1:]
data=json.load(open(p))
if key == 'clusterName': data[key]='region-b'
else: data['nodes'][0][key]={'hostname':'other.local:8091','services':['n1ql'],'status':'unhealthy','clusterMembership':'inactiveFailed'}[key]
json.dump(data,open(p,'w'))
JSONEDIT
    if initialize_primary >"$WORK/output" 2>&1; then echo "accepted wrong primary $change"; return 1; fi
  done
  [ "$(cat "$WORK/cluster-init-count")" -eq 0 ]
}
primary_permanent_failure() {
  startup_fixture; CLUSTER_FAIL=1
  if initialize_primary >"$WORK/output" 2>&1; then echo 'permanent cluster init accepted'; return 1; fi
  grep -q 'within 300s' "$WORK/output" && grep -q 'Internal server error' "$WORK/output"
}
join_transient_retry() {
  startup_fixture; primary_state; JOIN_TRANSIENT=1
  add_node cb-a-data-2 data >"$WORK/output" 2>&1 || { cat "$WORK/output"; return 1; }
  [ "$ADDED" -eq 1 ] && [ "$(cat "$WORK/server-add-count")" -eq 2 ]
}
join_partial_readback() {
  startup_fixture; primary_state; JOIN_PARTIAL=1
  add_node cb-a-data-2 data >"$WORK/output" 2>&1 || { cat "$WORK/output"; return 1; }
  [ "$ADDED" -eq 1 ] && [ "$(cat "$WORK/server-add-count")" -eq 1 ]
}
join_existing_membership() {
  startup_fixture; joined_state inactiveAdded
  add_node cb-a-data-2 data >"$WORK/output" 2>&1 || return 1
  [ "$ADDED" -eq 1 ] || { echo 'inactiveAdded member skipped rebalance'; return 1; }
  ADDED=0; joined_state active
  add_node cb-a-data-2 data >"$WORK/output" 2>&1 || return 1
  [ "$ADDED" -eq 0 ] && [ "$(cat "$WORK/server-add-count")" -eq 0 ]
}
join_permanent_failure() {
  startup_fixture; primary_state; JOIN_FAIL=1
  if add_node cb-a-data-2 data >"$WORK/output" 2>&1; then echo 'permanent join accepted'; return 1; fi
  [ "$ADDED" -eq 0 ] || { echo 'failed join counted'; return 1; }
  grep -q 'within 300s' "$WORK/output" && grep -q 'Join completion call failed' "$WORK/output"
}
join_wrong_state() {
  startup_fixture
  local membership
  for membership in inactiveFailed active; do
    joined_state "$membership"
    if [ "$membership" = active ]; then
      python3 - "$WORK/cluster.json" <<'JSONEDIT'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['nodes'][1]['services']=['n1ql']; json.dump(d,open(p,'w'))
JSONEDIT
    fi
    if add_node cb-a-data-2 data >"$WORK/output" 2>&1; then echo 'wrong joined member accepted'; return 1; fi
  done
  [ "$ADDED" -eq 0 ]
}
primary_success_without_readback() {
  startup_fixture; CLUSTER_NO_APPLY=1
  if initialize_primary >"$WORK/output" 2>&1; then echo 'CLI success accepted without initialized state'; return 1; fi
  grep -q 'within 300s' "$WORK/output"
}
join_success_without_readback() {
  startup_fixture; primary_state; JOIN_NO_APPLY=1
  if add_node cb-a-data-2 data >"$WORK/output" 2>&1; then echo 'CLI success accepted without joined state'; return 1; fi
  [ "$ADDED" -eq 0 ] && grep -q 'within 300s' "$WORK/output"
}
join_partial_wrong_readback() {
  startup_fixture; primary_state; JOIN_WRONG_APPLY=1 JOIN_PARTIAL=1
  if add_node cb-a-data-2 data >"$WORK/output" 2>&1; then echo 'partial CLI failure accepted with wrong applied state'; return 1; fi
  [ "$ADDED" -eq 0 ] && grep -q 'inactiveFailed' "$WORK/output"
}
partial_join_rebalanced_before_configured() {
  sed -n '/^all_nodes_ready$/,$p' "${INIT_SCRIPT:-$REPO/deploy/compose-cng/scripts/init-cluster.sh}" >"$WORK/init-main.sh"
  startup_fixture; primary_state; JOIN_PARTIAL=1
  DATA_NODES=(cb-a-data-2); QUERY_NODES=()
  configure_autofailover() { :; }; create_bucket() { :; }; create_index_and_marker() { :; }
  source "$WORK/init-main.sh" >"$WORK/output" 2>&1 || { cat "$WORK/output"; return 1; }
  [ "$ADDED" -eq 1 ] && [ "$(cat "$WORK/rebalance-count")" -eq 1 ] || { echo 'partial join did not trigger one rebalance'; return 1; }
  grep -q 'region-a configured' "$WORK/output"
}
topology_before_configured() {
  # Run real script bottom half; keep setup effects out, retain topology readback.
  sed -n '/^all_nodes_ready$/,$p' "${INIT_SCRIPT:-$REPO/deploy/compose-cng/scripts/init-cluster.sh}" >"$WORK/init-main.sh"
  startup_fixture; DATA_NODES=(cb-a-data-2 cb-a-data-3); QUERY_NODES=(cb-a-iq-1 cb-a-iq-2)
  cat >"$WORK/cluster.json" <<'JSON'
{"clusterName":"region-a","nodes":[{"hostname":"cb-a-data-1.local:8091","status":"healthy","clusterMembership":"active","services":["kv"]},{"hostname":"cb-a-data-2.local:8091","status":"healthy","clusterMembership":"active","services":["kv"]},{"hostname":"cb-a-data-3.local:8091","status":"healthy","clusterMembership":"active","services":["kv"]},{"hostname":"cb-a-iq-1.local:8091","status":"healthy","clusterMembership":"active","services":["index","n1ql"]},{"hostname":"cb-a-iq-2.local:8091","status":"healthy","clusterMembership":"active","services":["n1ql","index"]}]}
JSON
  all_nodes_ready() { :; }; initialize_primary() { :; }; wait_for_authenticated_cluster() { :; }
  add_node() { :; }; configure_autofailover() { :; }; create_bucket() { :; }; create_index_and_marker() { :; }
  source "$WORK/init-main.sh" >"$WORK/output" 2>&1 || return 1
  grep -q 'region-a configured' "$WORK/output" || return 1
  DATA_NODES=(cb-a-data-2); QUERY_NODES=()
  local change
  for change in missing extra services status clusterMembership clusterName; do
    joined_state active
    python3 - "$WORK/cluster.json" "$change" <<'JSONEDIT'
import json, sys
p,key=sys.argv[1:]; d=json.load(open(p))
if key == 'missing': d['nodes'].pop()
elif key == 'extra': d['nodes'].append(dict(d['nodes'][1],hostname='unexpected.local:8091'))
elif key == 'clusterName': d[key]='region-b'
else: d['nodes'][1][key]={'services':['n1ql'],'status':'unhealthy','clusterMembership':'inactiveAdded'}[key]
json.dump(d,open(p,'w'))
JSONEDIT
    if ( source "$WORK/init-main.sh" ) >"$WORK/output" 2>&1; then echo "configured with $change topology"; return 1; fi
    if grep -q 'region-a configured' "$WORK/output"; then echo 'printed configured before topology gate'; return 1; fi
  done
  # Single node region-b derives its expected services from primary env.
  REGION=b PRIMARY=cb-b-node-1 PRIMARY_SERVICES=data,index,query DATA_NODES=() QUERY_NODES=()
  echo '{"clusterName":"region-b","nodes":[{"hostname":"cb-b-node-1.local:8091","status":"healthy","clusterMembership":"active","services":["n1ql","kv","index"]}]}' >"$WORK/cluster.json"
  source "$WORK/init-main.sh" >"$WORK/output" 2>&1 || return 1
  grep -q 'region-b configured' "$WORK/output"
}

failed=0
for test in ${SETUP_TESTS:-primary_node_init_failure primary_transient_retry primary_partial_readback primary_wrong_configuration primary_permanent_failure join_transient_retry join_partial_readback join_existing_membership join_permanent_failure join_wrong_state primary_success_without_readback join_success_without_readback join_partial_wrong_readback partial_join_rebalanced_before_configured topology_before_configured transport_failure sql_failure nested_success invalid_response valid_response transient_retry persistent_failure marker_readiness index_readiness setup_verifies_readiness bounded_init_request node_deadline auth_deadline index_deadline readiness_success all_init_requests_bounded network_create_failure network_existing_subnet probe_budget local_ports}; do
  if ( "$test" ); then
    echo "PASS: $test"
  else
    echo "FAIL: $test"
    failed=$((failed+1))
  fi
done
[ "$failed" -eq 0 ]
