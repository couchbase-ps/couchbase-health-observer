#!/usr/bin/env bash
# CNG load-balancer failover scenarios.
#
#   lb_e2e.sh              run every scenario, then tear down
#   lb_e2e.sh up           bring the stack up and stop (manual demo)
#   lb_e2e.sh down         tear everything down
#   lb_e2e.sh scenario N   run one scenario against an already-up stack
#
# Scenarios 1 to 6 keep region-a down once it is killed, so auto-failback never
# fires mid-scenario. Scenario 7 is the one deliberate recovery run.
#
# Spec: delivery vault, CNG design and plan
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

scenario_1() {
  echo "== scenario 1: baseline, both regions healthy, expect zero errors =="
  run_harness s1 30
  wait_harness s1
  assert_eq "s1 no errors" "$(csv_summary s1 | sed 's/.*err=//')" "0"
  assert_eq "s1 served by region-a only" "$(csv_regions s1)" "a"
}

scenario_2() {
  echo "== scenario 2: one region-a data node lost, auto-failover absorbs, expect NO switch =="
  # 150s covers the ~10s detection, the 30s auto-failover, the rebalance, and
  # enough margin past the 60s Envoy window to prove the switch did not happen.
  run_harness s2 150
  sleep 10
  echo "-- stopping cb-a-data-2 --"
  docker stop cb-a-data-2 >/dev/null
  wait_harness s2
  assert_eq "s2 served by region-a only (no switch)" "$(csv_regions s2)" "a"
  assert_eq "s2 envoy kept region-a healthy" "$(envoy_health 172.28.1.10)" "healthy"
  local win; win="$(csv_error_window_ms s2)"
  echo "s2 error window: ${win}ms"
  assert_le "s2 recovered inside 60s" "$win" "60000"
  # Auto-failover absorbed the single-node loss above, which marks the node
  # "inactiveFailed" in pools/default: Couchbase leaves it listed, it does
  # NOT remove it, so a plain "docker start" brings the container back but
  # does not restore its cluster membership. recover_region_a detects the
  # inactiveFailed state and runs a full recovery plus rebalance to put it
  # back to "active" before any later scenario relies on region-a having all
  # three data nodes.
  echo "-- restoring cb-a-data-2 (auto-failover marked it inactiveFailed, not removed) --"
  recover_region_a
}

scenario_3() {
  echo "== scenario 3: two region-a data nodes lost, failover refused, expect SWITCH =="
  # Self-check: confirms scenario 2's recovery actually put region-a back at
  # its full 5-node baseline before this scenario's "stop two data nodes"
  # is asked to mean what it claims. Expected to find nothing to do.
  echo "-- verifying region-a is at full baseline before this scenario --"
  recover_region_a
  # Both nodes are stopped together so auto-failover cannot absorb either: with
  # replica 1 on three data nodes, the second failover would risk data loss and
  # is refused, so the Observer stays DOWN and the 60s window elapses.
  run_harness s3 180
  sleep 10
  echo "-- stopping cb-a-data-2 and cb-a-data-3 --"
  docker stop cb-a-data-2 cb-a-data-3 >/dev/null
  wait_harness s3
  assert_eq "s3 switched region-a to region-b" "$(csv_regions s3)" "a b"
  assert_eq "s3 envoy marked region-a unhealthy" "$(envoy_health 172.28.1.10)" "failed_active_hc"
  local win; win="$(csv_error_window_ms s3)"
  echo "s3 error window across the switch: ${win}ms"
  assert_le "s3 recovered inside 120s" "$win" "120000"
}

scenario_4() {
  echo "== scenario 4: whole region-a gone including its Observer, expect SWITCH on connect failure =="
  # Scenario 3 leaves region-a stopped (two data nodes down, envoy marked
  # unhealthy) with traffic already on region-b. Restore region-a to its full
  # baseline first, the same way scenario 3 itself undoes scenario 2's
  # damage before applying its own. Without this, scenario 4 starts on top
  # of scenario 3's outage and never exercises its own connection-failure
  # detection path: this is a real defect found by running the suite,
  # confirmed by scenario 4 originally showing regions=[b] with zero errors.
  echo "-- verifying region-a is at full baseline before this scenario --"
  recover_region_a
  assert_eq "s4 envoy routing to region-a before starting" "$(wait_envoy_healthy 172.28.1.10)" "healthy"
  # This is a different detection path from scenario 3: Envoy gets connection
  # refused rather than a 503, and a connection failure counts toward
  # unhealthy_threshold in the normal way.
  run_harness s4 180
  sleep 10
  echo "-- stopping every region-a container --"
  docker stop $REGION_A_NODES cng-a cb-a-observer >/dev/null
  wait_harness s4
  assert_eq "s4 switched region-a to region-b" "$(csv_regions s4)" "a b"
  assert_eq "s4 envoy marked region-a unhealthy" "$(envoy_health 172.28.1.10)" "failed_active_hc"
  local win; win="$(csv_error_window_ms s4)"
  echo "s4 error window across the switch: ${win}ms"
  # Bound derived, not fitted to an observation: worst case on this path is
  # unhealthy_threshold x (interval + timeout) = 12 x (5s + 4s) = 108s,
  # because a stopped container gives no RST so every check burns its full
  # timeout, and the next interval is scheduled from check completion rather
  # than check start. 150s sits about 42s above that mechanism's ceiling, to
  # absorb SDK reconnect and rebalance jitter without blinding the assertion.
  # The switch itself is asserted independently above, so a genuine failover
  # failure still fails regardless of this bound.
  assert_le "s4 recovered inside 150s" "$win" "150000"
}

scenario_5() {
  echo "== scenario 5: both regions down, expect fast clean errors not hangs =="
  # With fail_traffic_on_panic Envoy fails the connection instead of routing to
  # hosts it knows are unhealthy, so the SDK sees prompt errors. Without it,
  # panic mode would send traffic to a dead cluster and every operation would
  # burn its full timeout.
  echo "-- stopping region-b as well --"
  docker stop cb-b-node-1 cng-b cb-b-observer >/dev/null
  sleep 80
  run_harness s5 30
  wait_harness s5
  assert_eq "s5 zero successes" "$(csv_summary s5 | sed 's/ err=.*//; s/ok=//')" "0"
  # Every operation must fail well inside its own 2s KV timeout.
  local slow
  slow="$(awk -F, 'NR>1 && $2!="idle" && $4>2500 {c++} END {print c+0}' "$OUT_DIR/s5.csv")"
  assert_eq "s5 no operation exceeded 2500ms" "$slow" "0"
}

scenario_6() {
  echo "== scenario 6: idle client then resume, expect recovery =="
  # grpc-java sets no client keepalive, so this proves Envoy's 1h idle_timeout
  # is not silently resetting quiet channels and masquerading as a failover.
  echo "-- restoring both regions --"
  docker start $REGION_A_NODES cng-a cb-a-observer cb-b-node-1 cng-b cb-b-observer >/dev/null
  # Scenario 4 stopped every region-a node at once while the cluster was
  # healthy, so no auto-failover fired and the nodes are expected to rejoin
  # cleanly on restart. recover_region_a is membership-aware, so it verifies
  # that instead of assuming it: it repairs anything not "active" and asserts
  # all five nodes are active before this scenario relies on region-a.
  recover_region_a
  assert_eq "s6 envoy routing to region-a before starting" "$(wait_envoy_healthy 172.28.1.10)" "healthy"
  sleep 30
  run_harness s6 120 -e IDLE_AT_SECOND=15 -e IDLE_SECONDS=60
  wait_harness s6
  # Operations after the idle gap must succeed. The idle marker line splits the
  # file, so count errors only after it.
  local post_err
  post_err="$(awk -F, '$2=="idle" {seen=1; next} seen && $3=="err" {c++} END {print c+0}' \
    "$OUT_DIR/s6.csv")"
  assert_eq "s6 no errors after the idle gap" "$post_err" "0"
}

case "${1:-test}" in
  down) echo "== tearing down =="; stack_down; echo done; exit 0 ;;
  up)   stack_up; echo "== stack up, host ports: envoy 18098, admin 19901, observers 8181/8182 =="; exit "$FAIL" ;;
  scenario)
    "scenario_${2:?scenario number required}"
    exit "$FAIL"
    ;;
  readiness)
    # Task 12's evidence capture. Its own mode because it is not a numbered
    # scenario and must be runnable against an already-up stack.
    capture_cng_readiness
    exit "$FAIL"
    ;;
  test)
    trap stack_down EXIT
    stack_up
    scenario_1
    scenario_2
    scenario_3
    scenario_4
    scenario_5
    scenario_6
    if [ "$FAIL" -eq 0 ]; then echo "== ALL SCENARIOS PASSED =="; else echo "== SCENARIOS FAILED =="; fi
    exit "$FAIL"
    ;;
  *) echo "usage: lb_e2e.sh [up|down|test|scenario N]" >&2; exit 2 ;;
esac
