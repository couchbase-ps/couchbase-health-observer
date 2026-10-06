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
    echo '{"hostname":"cb-a-data-2.local:8091","status":"success","results":[1]}'
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
for path in pathlib.Path(sys.argv[1]).glob('*.json'):
    for name, service in json.loads(path.read_text())['services'].items():
        for port in service.get('ports', []):
            if port.get('host_ip') != '127.0.0.1':
                raise SystemExit(f'{path.stem}/{name} port {port["published"]} is not local-only')
print('all rendered host publications use 127.0.0.1')
PY
}

failed=0
for test in ${SETUP_TESTS:-transport_failure sql_failure nested_success invalid_response valid_response transient_retry persistent_failure marker_readiness index_readiness setup_verifies_readiness bounded_init_request node_deadline auth_deadline index_deadline readiness_success all_init_requests_bounded network_create_failure network_existing_subnet probe_budget local_ports}; do
  if ( "$test" ); then
    echo "PASS: $test"
  else
    echo "FAIL: $test"
    failed=$((failed+1))
  fi
done
[ "$failed" -eq 0 ]
