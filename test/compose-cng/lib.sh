#!/usr/bin/env bash
# Shared helpers for the CNG load-balancer scenario driver. Sourced, not run.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CNG_DIR="$REPO/deploy/compose-cng"
OUT_DIR="${OUT_DIR:-/tmp/cng-lb-out}"
HARNESS_IMAGE="cng-lb-harness:dev"
FAIL=0

COMPOSE_A="docker compose -p cng-a --env-file $CNG_DIR/env/region-a.env \
  -f $CNG_DIR/docker-compose.base.yml -f $CNG_DIR/docker-compose.region-a.yml"
COMPOSE_B="docker compose -p cng-b --env-file $CNG_DIR/env/region-b.env \
  -f $CNG_DIR/docker-compose.base.yml -f $CNG_DIR/docker-compose.region-b.yml"
COMPOSE_LB="docker compose -p cng-lb -f $CNG_DIR/envoy/docker-compose.yml"

REGION_A_NODES="cb-a-data-1 cb-a-data-2 cb-a-data-3 cb-a-iq-1 cb-a-iq-2"

assert_eq() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1 ($2)"
  else
    echo "FAIL: $1 (got=$2 want=$3)"
    FAIL=1
    return 1
  fi
}

assert_le() { # <label> <got> <max>
  if [ "$2" -lt 0 ] 2>/dev/null; then
    echo "FAIL: $1 (got=$2, negative measurement is undefined)"
    FAIL=1
  elif [ "$2" -le "$3" ] 2>/dev/null; then
    echo "PASS: $1 ($2 <= $3)"
  else
    echo "FAIL: $1 (got=$2 want<=$3)"
    FAIL=1
    return 1
  fi
}

stack_down() {
  $COMPOSE_LB down --remove-orphans >/dev/null 2>&1 || true
  $COMPOSE_A down -v --remove-orphans >/dev/null 2>&1 || true
  $COMPOSE_B down -v --remove-orphans >/dev/null 2>&1 || true
  "$CNG_DIR/net.sh" down >/dev/null 2>&1 || true
}

wait_observer() { # <hostport> <want> -> prints the status reached, or the last seen
  local port="$1" want="$2" last="NONE"
  for _ in $(seq 1 60); do
    last="$(curl --connect-timeout 2 --max-time 5 -s "http://localhost:$port/health/couchbase" | jq -r '.status // empty' 2>/dev/null)"
    [ "$last" = "$want" ] && { echo "$want"; return 0; }
    sleep 5
  done
  echo "${last:-NONE}"
  return 1
}

envoy_health() { # <cng ip> -> healthy | failed_active_hc | UNKNOWN
  local ip="$1" line
  line="$(curl --connect-timeout 2 --max-time 5 -s http://localhost:19901/clusters \
    | grep -E "cng_cluster::${ip}:18098::health_flags" || true)"
  case "$line" in
    *healthy*)            echo "healthy" ;;
    *failed_active_hc*)   echo "failed_active_hc" ;;
    *)                    echo "UNKNOWN" ;;
  esac
}

# wait_envoy_healthy <cng ip> [timeout_s] -> prints the health state reached.
# "Observer UP" is NOT the same as "Envoy is routing here again": Envoy needs
# healthy_threshold (2) x interval (5s) of successful checks before a recovered
# host takes new connections. A scenario that starts inside that window silently
# runs against the wrong region.
wait_envoy_healthy() {
  local ip="$1" secs="${2:-60}" i state
  for i in $(seq 1 "$secs"); do
    state="$(envoy_health "$ip")"
    [ "$state" = "healthy" ] && { echo "healthy"; return 0; }
    sleep 1
  done
  echo "$state"
  return 1
}

wait_envoy_unhealthy() {
  local ip="$1" secs="${2:-120}" state i
  for i in $(seq 1 "$secs"); do
    state="$(envoy_health "$ip")"
    [ "$state" = failed_active_hc ] && { echo "$state"; return 0; }
    sleep 1
  done
  echo "$state"
  return 1
}

# assert_marker <exec-container> <query-host> -> prints "a", "b", or MISSING.
# exec-container is any node in that region curl can run inside (a data node
# is always up); query-host is the node in that region actually running the
# query service, where init-cluster.sh wrote region::marker. Runs from the
# host through "docker exec" because only the data node's admin port, not the
# query port, is published to the host.
#
# This is the fix for a real defect: region-b's single node used to race data,
# index and query startup and could come up with no region::marker and no
# primary index at all. init-cluster.sh used to die silently on that race
# (CREATE PRIMARY INDEX returning HTTP 500 under set -euo pipefail), which
# turned a real, successful failover into an apparently-failed scenario 3,
# because the harness could not attribute traffic to a region it could not
# read a marker for. init-cluster.sh now retries and verifies the marker
# itself; this assertion is the second, independent guard so a missing marker
# fails setup loudly instead of degrading silently into "unattributed".
assert_marker() {
  local exec_node="$1" query_host="$2" out
  out="$(docker exec "$exec_node" curl --connect-timeout 2 --max-time 5 -fsS -u Administrator:password \
    "http://${query_host}:8093/query/service" \
    --data-urlencode 'statement=SELECT RAW region FROM `lbtest` USE KEYS "region::marker"' \
    2>/dev/null || true)"
  case "$out" in
    *'"a"'*) echo a ;;
    *'"b"'*) echo b ;;
    *)       echo MISSING ;;
  esac
}

wait_init() { # compose invocation string; setup job must exit within 600s
  local compose="$1" container state status info deadline
  container="$($compose ps -aq init)" || return $?
  [ -n "$container" ] || { echo "FAIL: no init container" >&2; FAIL=1; return 1; }
  deadline=$(( $(date +%s) + 600 ))
  while true; do
    info="$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$container")" || return $?
    read -r state status <<<"$info"
    case "$state" in
      exited)
        [ "$status" = 0 ] && return 0
        echo "FAIL: cluster init exit=$status" >&2
        FAIL=1; return 1
        ;;
      created|running|restarting) ;;
      *) echo "FAIL: cluster init $container unexpected state=$state exit=$status" >&2; FAIL=1; return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: cluster init $container did not exit within 600s (state=$state); inspect init logs" >&2
      FAIL=1; return 1
    fi
    sleep 3
  done
}

assert_stopped_membership() { # stopped node plus cluster's reported membership
  local node="$1" want="$2" running pools
  running="$(docker inspect --format '{{.State.Running}}' "$node")" || return $?
  assert_eq "$node container stopped" "$running" false || return $?
  pools="$(curl --connect-timeout 2 --max-time 5 -fsS -u Administrator:password http://localhost:8191/pools/default)" || return $?
  assert_eq "$node membership after outage" "$(node_membership "$pools" "$node")" "$want"
}

stack_up() {
  validate_output_dir || { FAIL=1; return 1; }
  stack_down
  # Otherwise an uploaded artifact mixes runs: a stale CSV or evidence file
  # left over from an earlier, possibly abandoned run would ship next to this
  # run's fresh output with no indication it is not current.
  rm -rf "$OUT_DIR" || return $?
  mkdir -p "$OUT_DIR" || return $?
  ensure_run || return $?
  "$CNG_DIR/net.sh" up || return $?
  "$CNG_DIR/scripts/make-certs.sh" || return $?
  docker build -t "$HARNESS_IMAGE" "$REPO/harness" || return $?
  $COMPOSE_A up -d --build || return $?
  $COMPOSE_B up -d --build || return $?
  wait_init "$COMPOSE_A" || return $?
  wait_init "$COMPOSE_B" || return $?
  echo "== waiting for both Observers =="
  assert_eq "region-a observer baseline" "$(wait_observer 8181 UP)" "UP"
  assert_eq "region-b observer baseline" "$(wait_observer 8182 UP)" "UP"
  echo "== asserting both region markers are readable before any scenario runs =="
  assert_eq "region-a marker readable" "$(assert_marker cb-a-data-1 cb-a-iq-1)" "a"
  assert_eq "region-b marker readable" "$(assert_marker cb-b-node-1 cb-b-node-1)" "b"
  $COMPOSE_LB up -d || return $?
  echo "== waiting for Envoy to health-check both priorities =="
  assert_eq "envoy region-a baseline" "$(wait_envoy_healthy 172.28.1.10)" "healthy"
  assert_eq "envoy region-b baseline" "$(wait_envoy_healthy 172.28.2.10)" "healthy"
}

# run_harness <csv name> <measured seconds> [extra -e KEY=VALUE pairs...]
# Returns only after current client starts measurement. Fault countdown follows.
run_harness() {
  local name="$1" secs="$2" required=true expected=a arg; shift 2
  for arg in "$@"; do
    case "$arg" in
      STARTUP_REQUIRED=*) required="${arg#*=}" ;;
      EXPECTED_REGION=*) expected="${arg#*=}" ;;
    esac
  done
  ensure_run || return $?
  rm -f "$OUT_DIR/$name.csv" "$OUT_DIR/$name.exit-code" \
    "$OUT_DIR/$name.ready.json" "$OUT_DIR/$name.startup.csv" "$OUT_DIR/$name.startup.json" || return $?
  docker run -d --name "cng-harness-$name" --label "cng.lb.run=$(cat "$OUT_DIR/run-id")" --network cng-lb-net \
    -v "$OUT_DIR:/out" \
    -v "$CNG_DIR/certs:/certs:ro" \
    -e CB_CONN="${CB_CONN:-couchbase2://cng-lb}" \
    -e TLS_CA="${TLS_CA:-/certs/ca.crt}" \
    -e CB_BUCKET=lbtest \
    -e OPS_PER_SEC=20 \
    -e QUERY_PER_SEC=1 \
    -e RUN_SECONDS="$secs" \
    -e RUN_ID="$(cat "$OUT_DIR/run-id")" \
    -e READY_FILE="/out/$name.ready.json" \
    -e STARTUP_CSV="/out/$name.startup.csv" \
    -e STARTUP_REQUIRED=true -e EXPECTED_REGION=a \
    -e OUT_CSV="/out/$name.csv" \
    "$@" \
    "$HARNESS_IMAGE" >/dev/null || { FAIL=1; return 1; }
  wait_harness_startup "$name" "$required" "$expected"
}

wait_harness_startup() { # bounded transport + data startup, then live measurement
  local name="$1" required="$2" expected="$3" deadline info state status ready_status
  deadline=$(( $(date +%s) + 90 ))
  while true; do
    info="$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' "cng-harness-$name")" || { FAIL=1; return 1; }
    read -r state status <<<"$info"
    if [ "$state" != running ]; then
      printf '%s\n' "$status" >"$OUT_DIR/$name.exit-code"
      docker logs "cng-harness-$name" >"$OUT_DIR/$name.harness.log" 2>&1 || true
      echo "FAIL: harness $name startup state=$state exit=$status" >&2
      FAIL=1; return 1
    fi
    if python3 - "$OUT_DIR/$name.ready.json" "$(cat "$OUT_DIR/run-id")" "$required" "$expected" <<'PYREADY'
import json, sys
try:
    with open(sys.argv[1]) as stream: ready = json.load(stream)
    required = sys.argv[3] == 'true'
    timestamp = ready.get('measurement_start_epoch_ms')
    valid = (ready.get('run_id') == sys.argv[2]
        and ready.get('warmup_required') is required
        and ready.get('ready') is required
        and type(timestamp) is int and timestamp > 0
        and (ready.get('observed_region') == sys.argv[4] if required else ready.get('observed_region') == ''))
except (OSError, ValueError, AttributeError):
    valid = False
raise SystemExit(0 if valid else 1)
PYREADY
    then ready_status=0
    else ready_status=1
    fi
    # Polling and validation can consume the remaining budget, even for a valid body.
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL: harness $name readiness did not validate within 90s" >&2
      FAIL=1; return 1
    fi
    if [ "$ready_status" -eq 0 ]; then
      echo "PASS: harness $name measurement started (warmup_required=$required expected_region=$expected)"
      return 0
    fi
    sleep 1
  done
}

wait_harness() { # <csv name>, preserve actual container exit before removing it
  local status command_status=0
  status="$(docker wait "cng-harness-$1")" || command_status=$?
  docker logs "cng-harness-$1" >"$OUT_DIR/$1.harness.log" 2>&1 || true
  docker inspect --format '{"image":{{json .Config.Image}},"image_id":{{json .Image}},"exit_code":{{.State.ExitCode}}}' "cng-harness-$1" >"$OUT_DIR/$1.harness.inspect.json" 2>&1 || true
  printf '%s\n' "$status" >"$OUT_DIR/$1.exit-code"
  docker rm -f "cng-harness-$1" >/dev/null 2>&1 || true
  if [ "$command_status" -ne 0 ] || [ "$status" != 0 ]; then
    echo "FAIL: harness $1 exit=$status docker_wait_exit=$command_status" >&2
    FAIL=1
    return 1
  fi
  write_summary "$1" || { FAIL=1; return 1; }
  cp "$OUT_DIR/run-id" "$OUT_DIR/$1.run-id" || return $?
}

csv_summary() { # <csv name> -> "ok=<n> err=<n>"
  awk -F, 'NR>1 && $2!="idle" {n[$3]++} END {printf "ok=%d err=%d\n", n["ok"]+0, n["err"]+0}' \
    "$OUT_DIR/$1.csv"
}

# Only exact successful observations establish region. Upserts have no provenance.
csv_regions() { python3 "$REPO/test/compose-cng/evidence.py" "$OUT_DIR/$1.csv" regions; }

# Largest zero-success gap using completion times, not operation start times.
# Partial successes can hide a permanent write outage. Recovery is separate.
csv_error_window_ms() { python3 "$REPO/test/compose-cng/evidence.py" "$OUT_DIR/$1.csv" gap; }

assert_recovery() {
  if ! python3 "$REPO/test/compose-cng/evidence.py" "$OUT_DIR/$1.csv" recovery; then
    FAIL=1
    return 1
  fi
  echo "PASS: $1 get/upsert/query sustained final recovery (>=10s)"
}

assert_negative() {
  if ! python3 "$REPO/test/compose-cng/evidence.py" "$OUT_DIR/$1.csv" negative; then
    FAIL=1
    return 1
  fi
}

epoch_ms() { python3 -c 'import time; print(time.time_ns() // 1000000)'; }
record_fault() {
  local at
  at="$(epoch_ms)"
  printf '%s\n' "$at" >"$OUT_DIR/$1.fault-ms"
  printf '{"scenario":"%s","fault_epoch_ms":%s}\n' "$1" "$at" >>"$OUT_DIR/fault-events.jsonl"
}

ensure_run() {
  mkdir -p "$OUT_DIR" || return $?
  if [ ! -s "$OUT_DIR/run-id" ]; then
    printf '%s-%s\n' "$(epoch_ms)" "$$" >"$OUT_DIR/run-id"
    git -C "$REPO" rev-parse HEAD >"$OUT_DIR/commit.txt" || return $?
    git -C "$REPO" diff >"$OUT_DIR/working-tree.patch" || return $?
  fi
}

write_summary() {
  local name="$1" fault=""
  [ ! -f "$OUT_DIR/$name.fault-ms" ] || fault="$(cat "$OUT_DIR/$name.fault-ms")"
  python3 "$REPO/test/compose-cng/evidence.py" "$OUT_DIR/$name.csv" summary "$fault" \
    >"$OUT_DIR/$name.summary.json" || return $?
}

assert_overlap() { # exact region-b old-client samples during new-client healthy-a run
  if ! python3 - "$OUT_DIR/$1.csv" "$OUT_DIR/$2.csv" "$3" >"$OUT_DIR/s7.overlap.summary.json" <<'PYOVERLAP'
import csv, json, sys
with open(sys.argv[1]) as stream: old = list(csv.DictReader(stream))
with open(sys.argv[2]) as stream: new = list(csv.DictReader(stream))
healthy = int(sys.argv[3])
def exact(rows, region):
    return [int(r['epoch_ms']) + int(r['latency_ms']) for r in rows if r['op'] in ('get', 'query') and r['outcome'] == 'ok' and r['region'] == region]
a, b = exact(new, 'a'), exact(old, 'b')
if not a or not b or min(int(r['epoch_ms']) for r in old) >= healthy:
    raise SystemExit('FAIL: client baseline/region observations missing')
left, right = max(healthy, min(a)), max(a)
observations = [t for t in b if left <= t <= right]
if not observations:
    raise SystemExit('FAIL: no exact old-client region-b observations during healthy-a new-client run')
print(json.dumps({'region_a_healthy_epoch_ms': healthy, 'overlap_start_epoch_ms': left, 'overlap_end_epoch_ms': right, 'old_client_region_b_observations': len(observations), 'new_client_region_a_observations': len(a)}, indent=2))
PYOVERLAP
  then
    FAIL=1
    return 1
  fi
}

# Scenario10 comparison requires successful same-run scenario2, not stale CSV.
require_s2_baseline() {
  if [ ! -s "$OUT_DIR/run-id" ] || [ ! -s "$OUT_DIR/s2.passed-run-id" ] \
      || [ "$(cat "$OUT_DIR/run-id")" != "$(cat "$OUT_DIR/s2.passed-run-id")" ] \
      || [ "$(cat "$OUT_DIR/s2.exit-code" 2>/dev/null)" != 0 ] \
      || ! python3 "$REPO/test/compose-cng/evidence.py" "$OUT_DIR/s2.csv" recovery; then
    echo "FAIL: s10 requires successful same-run s2 baseline" >&2
    FAIL=1
    return 1
  fi
}

validate_output_dir() {
  python3 - "$OUT_DIR" "$REPO" <<'PYOUT'
import pathlib, sys, tempfile
raw = sys.argv[1]
path, repo = pathlib.Path(raw).resolve(), pathlib.Path(sys.argv[2]).resolve()
roots = {pathlib.Path('/tmp').resolve(), pathlib.Path(tempfile.gettempdir()).resolve()}
inside_temp = any(root in path.parents for root in roots)
if not raw.strip() or not inside_temp or path in roots or path == repo or repo in path.parents or path in repo.parents or pathlib.Path(raw).is_symlink():
    raise SystemExit('unsafe OUT_DIR: ' + raw)
PYOUT
}

cleanup_harnesses() {
  [ -s "$OUT_DIR/run-id" ] || return 0
  local containers container name fault status=0
  containers="$(docker ps -a --filter "label=cng.lb.run=$(cat "$OUT_DIR/run-id")" --format '{{.Names}}')" || return $?
  for container in $containers; do
    case "$container" in cng-harness-*) ;; *) continue ;; esac
    name="${container#cng-harness-}"
    docker logs "$container" >"$OUT_DIR/$name.harness.log" 2>&1 || true
    docker inspect --format '{"image":{{json .Config.Image}},"image_id":{{json .Image}},"running":{{.State.Running}},"exit_code":{{.State.ExitCode}}}' "$container" >"$OUT_DIR/$name.harness.inspect.json" 2>&1 || true
    # Stop writer before measuring partial CSV, then remove only labelled workload.
    docker stop "$container" >"$OUT_DIR/$name.cleanup.log" 2>&1 || true
    fault=""
    [ ! -f "$OUT_DIR/$name.fault-ms" ] || fault="$(cat "$OUT_DIR/$name.fault-ms")"
    python3 "$REPO/test/compose-cng/evidence.py" "$OUT_DIR/$name.csv" summary "$fault" \
      >"$OUT_DIR/$name.partial.summary.json" 2>"$OUT_DIR/$name.partial.summary.error" || true
    docker rm -f "$container" >>"$OUT_DIR/$name.cleanup.log" 2>&1 || status=$?
  done
  return "$status"
}

capture_artifacts() {
  local exit_status="${1:-0}"
  [ -d "$OUT_DIR" ] || return 0
  docker version >"$OUT_DIR/docker-version.txt" 2>&1 || true
  $COMPOSE_A config >"$OUT_DIR/compose-a.yml" 2>&1 || true
  $COMPOSE_B config >"$OUT_DIR/compose-b.yml" 2>&1 || true
  $COMPOSE_LB config >"$OUT_DIR/compose-lb.yml" 2>&1 || true
  cp "$CNG_DIR/envoy/envoy.yaml" "$OUT_DIR/envoy.yaml" || true
  local node
  for node in $REGION_A_NODES cng-a cb-a-observer cb-b-node-1 cng-b cb-b-observer cng-envoy cb-a-init cb-b-init; do
    docker logs "$node" >"$OUT_DIR/$node.log" 2>&1 || true
    docker inspect --format '{"image":{{json .Config.Image}},"image_id":{{json .Image}},"running":{{.State.Running}},"status":{{json .State.Status}},"exit_code":{{.State.ExitCode}},"oom_killed":{{.State.OOMKilled}},"error":{{json .State.Error}},"started_at":{{json .State.StartedAt}},"finished_at":{{json .State.FinishedAt}},"memory_limit_bytes":{{.HostConfig.Memory}}}' "$node" >"$OUT_DIR/$node.inspect.json" 2>&1 || true
    local image
    image="$(docker inspect --format '{{.Image}}' "$node" 2>/dev/null)" || continue
    docker image inspect --format '{"id":{{json .Id}},"digests":{{json .RepoDigests}},"os":{{json .Os}},"architecture":{{json .Architecture}}}' "$image" >"$OUT_DIR/$node.image.json" 2>&1 || true
  done
  if [ "$exit_status" -ne 0 ]; then
    # Internal server logs explain init/join failures that docker logs omits.
    # Copy only these test nodes and four diagnostic files, before teardown.
    local log
    for node in $REGION_A_NODES cb-b-node-1; do
      if ! mkdir -p "$OUT_DIR/$node.internal"; then
        echo "WARNING: cannot create diagnostic directory $OUT_DIR/$node.internal; skipping internal logs" >&2 || true
        continue
      fi
      for log in error.log debug.log babysitter.log memcached.log; do
        docker cp "$node:/opt/couchbase/var/lib/couchbase/logs/$log" \
          "$OUT_DIR/$node.internal/$log" >>"$OUT_DIR/$node.internal/capture.log" 2>&1 || true
      done
    done
  fi
}

# node_membership <pools/default json> <node short name> -> prints the
# clusterMembership value ("active", "inactiveAdded", "inactiveFailed") for
# that node, or empty if the node is genuinely absent from the nodes array.
# Parsed with jq rather than grepped, because a grep for the hostname string
# alone cannot tell "active" apart from "inactiveFailed": Couchbase
# auto-failover sets clusterMembership to "inactiveFailed" but LEAVES the
# failed node in the nodes array, and only an explicit rebalance-out removes
# it. A hostname-presence grep reports "already has all 5 nodes" even for a
# failed-over, inactive node, which is a defect this function exists to avoid
# repeating.
node_membership() {
  echo "$1" | jq -r --arg h "$2.local:8091" \
    '.nodes[]? | select(.hostname==$h) | .clusterMembership' 2>/dev/null
}

# wait_pools_default [timeout_s] -> prints a well-formed pools/default JSON
# body on stdout and returns 0, or returns 1 after the timeout with nothing
# printed.
#
# recover_region_a execs this read through cb-a-data-1, but cb-a-data-1 is
# itself one of the containers it just "docker start"ed: right after a total
# region-a restart (scenario 6, following scenario 4's "stop everything"),
# cb-a-data-1's own management API is not listening yet. A bare curl at that
# moment returns empty, and an empty or unparseable body must never be read
# as "every node is absent from the cluster": that misclassification is what
# previously drove five doomed server-add calls ("joining node to itself",
# "already part of cluster"), rescued only by a rebalance that ran anyway.
# This polls until the response actually parses as a pools/default body with
# a non-empty node list, so "cluster not answering yet" and "node genuinely
# absent" are never confused.
wait_pools_default() {
  local secs="${1:-60}" i pools count
  for i in $(seq 1 "$secs"); do
    pools="$(curl --connect-timeout 2 --max-time 5 -fsS -u Administrator:password http://localhost:8191/pools/default 2>/dev/null || true)"
    count="$(echo "$pools" | jq -r '.nodes | length' 2>/dev/null || true)"
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
      echo "$pools"
      return 0
    fi
    sleep 1
  done
  return 1
}

# wait_rebalance_idle [timeout_s] -> prints "ok" and returns 0 once the
# cluster's own rebalance task is not running and finished with no error;
# prints the cluster's own error message (or "timeout: ...") and returns 1
# otherwise.
#
# "couchbase-cli rebalance" returning 0 is not proof the rebalance actually
# completed cleanly, and a node reading back "active" in pools/default is
# even less proof: a rebalance that fails partway through can leave uneven
# vBucket ownership while every node still shows "active", since membership
# and data placement are two different things. Confirmed against a live
# 8.0.1-4792-enterprise cluster: /pools/default/tasks always carries exactly
# one entry with type "rebalance"; its "status" is "running" or "notRunning",
# and on a failed rebalance it additionally carries an "errorMessage" field
# that is simply absent after a clean one. That field, not the CLI's exit
# code and not node membership, is the source of truth used here.
wait_rebalance_idle() {
  local secs="${1:-120}" i tasks status err
  for i in $(seq 1 "$secs"); do
    tasks="$(curl --connect-timeout 2 --max-time 5 -fsS -u Administrator:password http://localhost:8191/pools/default/tasks 2>/dev/null || true)"
    status="$(echo "$tasks" | jq -r '.[] | select(.type=="rebalance") | .status' 2>/dev/null)"
    if [ "$status" = "notRunning" ]; then
      err="$(echo "$tasks" | jq -r '.[] | select(.type=="rebalance") | .errorMessage // empty' 2>/dev/null)"
      if [ -n "$err" ]; then
        echo "$err"
        return 1
      fi
      echo "ok"
      return 0
    fi
    sleep 1
  done
  echo "timeout: rebalance still running or cluster unreachable after ${secs}s"
  return 1
}

# recover_region_a: after Couchbase auto-failover, a node is marked
# "inactiveFailed" but stays listed in pools/default; a plain "docker start"
# brings its container back but does NOT restore its cluster membership. The
# two cases need two different couchbase-cli repairs:
#   - genuinely absent from pools/default -> server-add
#   - listed but not "active" (inactiveFailed/inactiveAdded) -> a full
#     recovery (couchbase-cli recovery --recovery-type full)
# A rebalance only runs when at least one of those repairs actually
# succeeded; a repair that fails is counted as a failure, not silently
# absorbed by a rebalance run regardless. Stopping two data nodes together
# (scenario 3) is refused by auto-failover, so this is expected to be a
# no-op there; scenario 2's single-node loss is expected to need the
# recovery path, since auto-failover only ever produces "inactiveFailed",
# never removal from pools/default.
#
# Starts every region-a container, waits for cb-a-data-1's management API to
# return a real pools/default body (see wait_pools_default), repairs
# whatever is not "active", rebalances only if a repair actually succeeded
# and verifies that rebalance actually finished with no error (see
# wait_rebalance_idle; a retry, not a shrug, is what happens on a genuine
# rebalance failure), waits for region-a's Observer to report UP, then
# re-reads pools/default and fails loudly if any of the five nodes is still
# not "active".
recover_region_a() {
  echo "== recover_region_a: checking region-a cluster membership =="
  local n svc pools membership attempted=0 repaired=0 ok

  # Starts cng-a and cb-a-observer too, not just the five Couchbase nodes:
  # this function asserts on the Observer and on Envoy's view of region-a
  # below, so it must be the one that starts everything those assertions
  # depend on. It previously relied on the caller having already started
  # those two, which happened to hold for every existing call site but is
  # exactly the kind of call-site-order fragility this function exists to
  # remove.
  for n in $REGION_A_NODES cng-a cb-a-observer; do
    docker start "$n" >/dev/null || return $?
  done

  echo "-- waiting for cb-a-data-1's management API to answer pools/default --"
  if ! pools="$(wait_pools_default 60)"; then
    echo "FAIL: recover_region_a: pools/default never returned a well-formed node list within 60s"
    FAIL=1
    return 1
  fi

  for n in $REGION_A_NODES; do
    case "$n" in
      cb-a-iq-*) svc="index,query" ;;
      *)         svc="data" ;;
    esac
    membership="$(node_membership "$pools" "$n")"

    if [ "$membership" = "active" ]; then
      continue
    fi

    attempted=$((attempted+1))
    ok=0
    if [ -z "$membership" ]; then
      echo "-- $n absent from pools/default, re-adding --"
      if docker exec cb-a-data-1 bash -c \
          "for _ in \$(seq 1 60); do curl --connect-timeout 2 --max-time 5 -sS -o /dev/null http://$n:8091 2>/dev/null && exit 0; sleep 3; done; exit 1"; then
        if docker exec cb-a-data-1 /opt/couchbase/bin/couchbase-cli server-add \
            --cluster https://cb-a-data-1:18091 \
            --username Administrator --password password \
            --server-add "https://$n.local:18091" \
            --server-add-username Administrator --server-add-password password \
            --services "$svc" --no-ssl-verify; then
          ok=1
        fi
      else
        echo "-- $n did not come up on port 8091 within 180s --"
      fi
    else
      echo "-- $n is ${membership} in pools/default, running full recovery --"
      if docker exec cb-a-data-1 /opt/couchbase/bin/couchbase-cli recovery \
          --cluster https://cb-a-data-1:18091 \
          --username Administrator --password password \
          --server-recovery "$n.local:8091" \
          --recovery-type full --no-ssl-verify; then
        ok=1
      fi
    fi

    if [ "$ok" -eq 1 ]; then
      repaired=$((repaired+1))
    else
      echo "FAIL: recover_region_a: repair of $n failed"
      FAIL=1
    fi
  done

  if [ "$repaired" -gt 0 ]; then
    # Third silent-failure guard in this function: neither the CLI's own exit
    # status nor "every node reads back active" afterward is proof the
    # rebalance actually finished cleanly. A rebalance that fails partway can
    # leave uneven vBucket ownership while membership still shows "active"
    # for all five nodes, so this checks the cluster's own rebalance task
    # (wait_rebalance_idle) as the real source of truth, retries the whole
    # rebalance once on a genuine failure, and only then gives up loudly.
    local rebalance_ok=0 attempt cli_status verify
    for attempt in 1 2; do
      echo "-- rebalancing region-a after recovery/re-add (attempt $attempt of 2) --"
      cli_status=0
      docker exec cb-a-data-1 /opt/couchbase/bin/couchbase-cli rebalance \
        --cluster https://cb-a-data-1:18091 \
        --username Administrator --password password --no-ssl-verify || cli_status=$?

      echo "-- verifying the rebalance actually completed (the CLI returning is not proof by itself) --"
      verify="$(wait_rebalance_idle 120)"
      if [ "$cli_status" -eq 0 ] && [ "$verify" = "ok" ]; then
        rebalance_ok=1
        break
      fi
      echo "-- rebalance attempt $attempt did not verify complete: cli_exit=$cli_status cluster_report=$verify --"
    done

    if [ "$rebalance_ok" -eq 1 ]; then
      echo "-- rebalance verified complete --"
    else
      echo "FAIL: recover_region_a: rebalance did not complete successfully after a retry"
      FAIL=1
    fi
  elif [ "$attempted" -gt 0 ]; then
    echo "-- all attempted repairs failed, skipping rebalance --"
  else
    echo "-- region-a already has all 5 nodes active, nothing to recover --"
  fi

  assert_eq "region-a observer UP after recovery" "$(wait_observer 8181 UP)" "UP"

  echo "== recover_region_a: verifying all five nodes are active =="
  pools="$(curl --connect-timeout 2 --max-time 5 -fsS -u Administrator:password http://localhost:8191/pools/default 2>/dev/null || true)"
  for n in $REGION_A_NODES; do
    membership="$(node_membership "$pools" "$n")"
    assert_eq "region-a $n active after recovery" "$membership" "active"
  done

  # "Observer UP" above only means the cluster answers; it does not mean
  # Envoy is routing new connections here again. Envoy needs
  # healthy_threshold (2) x interval (5s) of passing checks first, so wait
  # for that too before declaring region-a recovered.
  assert_eq "region-a envoy healthy after recovery" "$(wait_envoy_healthy 172.28.1.10)" "healthy"
  [ "$FAIL" -eq 0 ]
}
