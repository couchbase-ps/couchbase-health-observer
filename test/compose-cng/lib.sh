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
  fi
}

assert_le() { # <label> <got> <max>
  if [ "$2" -lt 0 ] 2>/dev/null; then
    echo "FAIL: $1 (got=$2, negative means it never recovered)"
    FAIL=1
  elif [ "$2" -le "$3" ] 2>/dev/null; then
    echo "PASS: $1 ($2 <= $3)"
  else
    echo "FAIL: $1 (got=$2 want<=$3)"
    FAIL=1
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
    last="$(curl -s "http://localhost:$port/health/couchbase" | jq -r '.status // empty' 2>/dev/null)"
    [ "$last" = "$want" ] && { echo "$want"; return 0; }
    sleep 5
  done
  echo "${last:-NONE}"
}

envoy_health() { # <cng ip> -> healthy | failed_active_hc | UNKNOWN
  local ip="$1" line
  line="$(curl -s http://localhost:19901/clusters \
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
  out="$(docker exec "$exec_node" curl -fsS -u Administrator:password \
    "http://${query_host}:8093/query/service" \
    --data-urlencode 'statement=SELECT RAW region FROM `lbtest` USE KEYS "region::marker"' \
    2>/dev/null || true)"
  case "$out" in
    *'"a"'*) echo a ;;
    *'"b"'*) echo b ;;
    *)       echo MISSING ;;
  esac
}

stack_up() {
  stack_down
  # Otherwise an uploaded artifact mixes runs: a stale CSV or evidence file
  # left over from an earlier, possibly abandoned run would ship next to this
  # run's fresh output with no indication it is not current.
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR"
  "$CNG_DIR/net.sh" up
  "$CNG_DIR/scripts/make-certs.sh"
  docker build -t "$HARNESS_IMAGE" "$REPO/harness"
  $COMPOSE_A up -d --build
  $COMPOSE_B up -d --build
  echo "== waiting for both Observers =="
  assert_eq "region-a observer baseline" "$(wait_observer 8181 UP)" "UP"
  assert_eq "region-b observer baseline" "$(wait_observer 8182 UP)" "UP"
  echo "== asserting both region markers are readable before any scenario runs =="
  assert_eq "region-a marker readable" "$(assert_marker cb-a-data-1 cb-a-iq-1)" "a"
  assert_eq "region-b marker readable" "$(assert_marker cb-b-node-1 cb-b-node-1)" "b"
  $COMPOSE_LB up -d
  echo "== waiting for Envoy to health-check both priorities =="
  assert_eq "envoy region-a baseline" "$(wait_envoy_healthy 172.28.1.10)" "healthy"
  assert_eq "envoy region-b baseline" "$(wait_envoy_healthy 172.28.2.10)" "healthy"
}

# run_harness <csv name> <seconds> [extra -e KEY=VALUE pairs...]
# Runs detached and returns immediately, so the caller can inject a failure
# while traffic is flowing. Container name is cng-harness-<csv name>.
run_harness() {
  local name="$1" secs="$2"; shift 2
  docker rm -f "cng-harness-$name" >/dev/null 2>&1 || true
  docker run -d --name "cng-harness-$name" --network cng-lb-net \
    -v "$OUT_DIR:/out" \
    -v "$CNG_DIR/certs:/certs:ro" \
    -e CB_CONN="${CB_CONN:-couchbase2://cng-lb}" \
    -e TLS_CA="${TLS_CA:-/certs/ca.crt}" \
    -e CB_BUCKET=lbtest \
    -e OPS_PER_SEC=20 \
    -e QUERY_PER_SEC=1 \
    -e RUN_SECONDS="$secs" \
    -e OUT_CSV="/out/$name.csv" \
    "$@" \
    "$HARNESS_IMAGE" >/dev/null
}

wait_harness() { # <csv name>
  docker wait "cng-harness-$1" >/dev/null 2>&1 || true
  docker rm -f "cng-harness-$1" >/dev/null 2>&1 || true
}

csv_summary() { # <csv name> -> "ok=<n> err=<n>"
  awk -F, 'NR>1 && $2!="idle" {n[$3]++} END {printf "ok=%d err=%d\n", n["ok"]+0, n["err"]+0}' \
    "$OUT_DIR/$1.csv"
}

# csv_regions <csv name> -> space separated regions in first-seen order,
# e.g. "a b". This is how a switch is proven.
csv_regions() {
  awk -F, 'NR>1 && $5!="" && !seen[$5]++ {printf "%s%s", sep, $5; sep=" "} END {print ""}' \
    "$OUT_DIR/$1.csv"
}

# csv_error_window_ms <csv name> -> longest stretch in milliseconds containing
# no successful operation, counting the whole run. This is the
# customer-visible availability gap.
#
# A naive "first error to first success after it" measure is wrong here:
# during a partial outage the surviving data node keeps serving some
# vbuckets, so successes interleave with failures throughout the outage, and
# that measure latches onto the first success after the very first error,
# which can be a 1-2ms blip instead of the real multi-second outage.
#
# Measuring only gaps BETWEEN two "ok" rows is also wrong: it misses a
# leading outage (failures before the first success) and a trailing outage
# (failures running to the end of the run with no later success), because
# neither has an "ok" row on both sides to measure between. The first
# non-idle row's timestamp is the run's start boundary and the last
# non-idle row's timestamp is its end boundary, so a leading or trailing gap
# is measured against those instead of being skipped.
#
# -1 when the run recorded no successful operation at all: that is not a
# passing zero-length window, it is an undefined gap, and the caller must
# treat -1 as a failed bound, same as before.
#
# A scenario 6 style deliberate idle gap is not an outage: the harness marks
# it with an "idle" row ("epoch_ms,idle,ok,0,,sleeping Ns") before it sleeps.
# That span is skipped by advancing the last-success marker to the end of the
# sleep, so a deliberate idle period never shows up as a measured gap.
csv_error_window_ms() {
  awk -F, '
    NR>1 && $2=="idle" {
      dur=$6
      sub(/^sleeping /, "", dur)
      sub(/s$/, "", dur)
      idle_end=$1+dur*1000
      if (prev=="" || idle_end>prev) prev=idle_end
      next
    }
    NR>1 && $2!="idle" {
      if (start=="") start=$1
      end=$1
      if ($3=="ok") {
        if (prev=="") { g=$1-start } else { g=$1-prev }
        if (g>max) max=g
        prev=$1; seen=1
      }
    }
    END {
      if (!seen) { print -1; exit }
      g=end-prev
      if (g>max) max=g
      print max+0
    }' "$OUT_DIR/$1.csv"
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
    pools="$(curl -fsS -u Administrator:password http://localhost:8191/pools/default 2>/dev/null || true)"
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
    tasks="$(curl -fsS -u Administrator:password http://localhost:8191/pools/default/tasks 2>/dev/null || true)"
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
    docker start "$n" >/dev/null 2>&1 || true
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
          "for _ in \$(seq 1 60); do curl -sS -o /dev/null http://$n:8091 2>/dev/null && exit 0; sleep 3; done; exit 1"; then
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
  pools="$(curl -fsS -u Administrator:password http://localhost:8191/pools/default 2>/dev/null || true)"
  for n in $REGION_A_NODES; do
    membership="$(node_membership "$pools" "$n")"
    assert_eq "region-a $n active after recovery" "$membership" "active"
  done

  # "Observer UP" above only means the cluster answers; it does not mean
  # Envoy is routing new connections here again. Envoy needs
  # healthy_threshold (2) x interval (5s) of passing checks first, so wait
  # for that too before declaring region-a recovered.
  assert_eq "region-a envoy healthy after recovery" "$(wait_envoy_healthy 172.28.1.10)" "healthy"
}
