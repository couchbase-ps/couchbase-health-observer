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
  # Auto-failover absorbed the single-node loss above, which REMOVES the node
  # from the cluster map: a plain "docker start" would leave region-a on only
  # two data nodes for every scenario after this one. recover_region_a
  # server-adds and rebalances it back in.
  echo "-- restoring cb-a-data-2 (auto-failover removed it from the cluster map) --"
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
    if [ "$FAIL" -eq 0 ]; then echo "== ALL SCENARIOS PASSED =="; else echo "== SCENARIOS FAILED =="; fi
    exit "$FAIL"
    ;;
  *) echo "usage: lb_e2e.sh [up|down|test|scenario N]" >&2; exit 2 ;;
esac
