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
  sleep 20
  assert_eq "envoy region-a baseline" "$(envoy_health 172.28.1.10)" "healthy"
  assert_eq "envoy region-b baseline" "$(envoy_health 172.28.2.10)" "healthy"
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

# recover_region_a: after Couchbase auto-failover, a node is marked
# "inactiveFailed" but stays listed in pools/default; a plain "docker start"
# brings its container back but does NOT restore its cluster membership. The
# two cases need two different couchbase-cli repairs:
#   - genuinely absent from pools/default -> server-add
#   - listed but not "active" (inactiveFailed/inactiveAdded) -> a full
#     recovery (couchbase-cli recovery --recovery-type full)
# Either case is followed by one rebalance to actually apply it. Stopping two
# data nodes together (scenario 3) is refused by auto-failover, so this is
# expected to be a no-op there; scenario 2's single-node loss is expected to
# need the recovery path, since auto-failover only ever produces
# "inactiveFailed", never removal from pools/default.
#
# Starts every region-a container, reads pools/default once (through
# cb-a-data-1, which no scenario ever stops), repairs whatever is not
# "active", rebalances if anything was repaired, waits for region-a's
# Observer to report UP, then re-reads pools/default and fails loudly if any
# of the five nodes is still not "active".
recover_region_a() {
  echo "== recover_region_a: checking region-a cluster membership =="
  local n svc pools membership repaired=0

  for n in $REGION_A_NODES; do
    docker start "$n" >/dev/null 2>&1 || true
  done

  pools="$(curl -fsS -u Administrator:password http://localhost:8191/pools/default 2>/dev/null || true)"

  for n in $REGION_A_NODES; do
    case "$n" in
      cb-a-iq-*) svc="index,query" ;;
      *)         svc="data" ;;
    esac
    membership="$(node_membership "$pools" "$n")"

    if [ "$membership" = "active" ]; then
      continue
    fi

    if [ -z "$membership" ]; then
      echo "-- $n absent from pools/default, re-adding --"
      if ! docker exec cb-a-data-1 bash -c \
          "for _ in \$(seq 1 60); do curl -sS -o /dev/null http://$n:8091 2>/dev/null && exit 0; sleep 3; done; exit 1"; then
        echo "FAIL: recover_region_a: $n did not come up on port 8091 within 180s"
        FAIL=1
        continue
      fi
      docker exec cb-a-data-1 /opt/couchbase/bin/couchbase-cli server-add \
        --cluster https://cb-a-data-1:18091 \
        --username Administrator --password password \
        --server-add "https://$n.local:18091" \
        --server-add-username Administrator --server-add-password password \
        --services "$svc" --no-ssl-verify
    else
      echo "-- $n is ${membership} in pools/default, running full recovery --"
      docker exec cb-a-data-1 /opt/couchbase/bin/couchbase-cli recovery \
        --cluster https://cb-a-data-1:18091 \
        --username Administrator --password password \
        --server-recovery "$n.local:8091" \
        --recovery-type full --no-ssl-verify
    fi
    repaired=$((repaired+1))
  done

  if [ "$repaired" -gt 0 ]; then
    echo "-- rebalancing region-a after recovery/re-add --"
    docker exec cb-a-data-1 /opt/couchbase/bin/couchbase-cli rebalance \
      --cluster https://cb-a-data-1:18091 \
      --username Administrator --password password --no-ssl-verify
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
