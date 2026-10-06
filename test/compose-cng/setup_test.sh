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
for test in ${SETUP_TESTS:-transport_failure sql_failure nested_success invalid_response valid_response transient_retry persistent_failure marker_readiness index_readiness setup_verifies_readiness probe_budget local_ports}; do
  if ( "$test" ); then
    echo "PASS: $test"
  else
    echo "FAIL: $test"
    failed=$((failed+1))
  fi
done
[ "$failed" -eq 0 ]
