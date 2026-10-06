#!/usr/bin/env bash
# Offline evidence regressions. Docker mocks only replace unavailable infrastructure.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export OUT_DIR="$WORK/out"
mkdir -p "$OUT_DIR"
source "$REPO/test/compose-cng/lib.sh"
# Load actual scenario functions without invoking driver dispatch.
sed '/^case "${1:-test}" in/,$d' "$REPO/test/compose-cng/lb_e2e.sh" >"$WORK/scenarios.sh"
source "$WORK/scenarios.sh"
sleep() { :; }
docker() { :; }
header() { echo 'epoch_ms,op,outcome,latency_ms,region,detail' >"$OUT_DIR/$1.csv"; }
expect_failure() {
  local status=0
  "$@" >"$WORK/output" 2>&1 || status=$?
  if [ "$status" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    cat "$WORK/output"; echo 'accepted invalid evidence'; return 1
  fi
}
empty_s5() {
  header s5
  run_harness() { :; }; wait_harness() { :; }
  envoy_health() { echo failed_active_hc; }
  expect_failure scenario_5
}
crashed_harness() {
  header crash
  docker() { if [ "$1" = wait ]; then echo 137; else :; fi; }
  expect_failure wait_harness crash
}
missing_s2() {
  recover_region_a() { echo called >>"$WORK/damage"; }
  wait_envoy_healthy() { echo healthy; }
  run_harness() { echo called >>"$WORK/damage"; header s10; }
  wait_harness() { :; }
  curl() { echo '{"status":"UP"}'; }
  envoy_health() { echo healthy; }
  expect_failure scenario_10 || return 1
  [ ! -e "$WORK/damage" ] || { echo 'missing baseline damaged stack'; return 1; }
}
permanent_write_outage() {
  header permanent
  for t in $(seq 0 1000 180000); do
    echo "$t,get,ok,10,a," >>"$OUT_DIR/permanent.csv"
    echo "$t,upsert,err,2000,,timeout" >>"$OUT_DIR/permanent.csv"
    echo "$t,query,ok,10,a," >>"$OUT_DIR/permanent.csv"
  done
  assert_le 'zero-success gap still small' "$(csv_error_window_ms permanent)" 120000
  recover_region_a() { :; }; run_harness() { :; }; wait_harness() { :; }
  envoy_health() { echo failed_active_hc; }; csv_regions() { echo "a b"; }
  assert_stopped_membership() { :; }
  cp "$OUT_DIR/permanent.csv" "$OUT_DIR/s3.csv"
  expect_failure scenario_3
}
terminal_recovery() {
  header recovered
  for op in get upsert query; do
    echo "0,$op,err,2000,,timeout" >>"$OUT_DIR/recovered.csv"
    for t in 3000 8000 13000; do echo "$t,$op,ok,10,," >>"$OUT_DIR/recovered.csv"; done
  done
  assert_recovery recovered || return 1
  [ "$FAIL" -eq 0 ]
}
short_recovery() {
  header short
  for op in get upsert query; do
    echo "0,$op,err,2000,,timeout" >>"$OUT_DIR/short.csv"
    echo "3000,$op,ok,10,," >>"$OUT_DIR/short.csv"
    echo "6000,$op,ok,10,," >>"$OUT_DIR/short.csv"
  done
  declare -F assert_recovery >/dev/null || { echo "terminal recovery gate missing"; return 1; }
  expect_failure assert_recovery short
}
exact_regions() {
  header exact
  cat >>"$OUT_DIR/exact.csv" <<'CSV'
0,get,err,1,a,timeout
1,upsert,ok,1,a,
2,get,ok,1,b,
3,query,ok,1,a,
4,connect,err,1,c,timeout
CSV
  [ "$(csv_regions exact)" = 'b a' ]
}
completion_gap() {
  header completion
  cat >>"$OUT_DIR/completion.csv" <<'CSV'
0,get,ok,10,a,
1000,upsert,err,2000,,timeout
CSV
  [ "$(csv_error_window_ms completion)" = 2990 ]
}
unsafe_output() {
  stack_down() { echo called >>"$WORK/damage"; }
  rm() { :; }; mkdir() { :; }
  for OUT_DIR in / '' "$REPO" "$REPO/.."; do
    FAIL=0
    expect_failure stack_up || return 1
    [ ! -e "$WORK/damage" ] || { echo 'unsafe path mutated stack'; return 1; }
  done
}
failed_prerequisite() {
  wait_observer() { echo UP; }; assert_marker() { echo a; }; wait_envoy_healthy() { echo healthy; }
  stack_down() { :; }
  CNG_DIR="$WORK/cng"; mkdir -p "$CNG_DIR/scripts"
  printf '#!/bin/sh\nexit 23\n' >"$CNG_DIR/net.sh"; chmod +x "$CNG_DIR/net.sh"
  printf '#!/bin/sh\necho called >"%s"\n' "$WORK/damage" >"$CNG_DIR/scripts/make-certs.sh"
  chmod +x "$CNG_DIR/scripts/make-certs.sh"
  expect_failure stack_up || return 1
  [ ! -e "$WORK/damage" ] || { echo 'continued after failed prerequisite'; return 1; }
  [ -s "$OUT_DIR/commit.txt" ] || { echo 'failed prerequisite lacks run provenance'; return 1; }
}
missing_tls_verify() {
  recover_region_a() { :; }; wait_observer() { echo UP; }; wait_envoy_healthy() { echo healthy; }
  csv_regions() { echo "a b"; }; csv_error_window_ms() { echo 0; }
  echo 0 >"$WORK/tls-count"
  tls_verify_code() { local n; n="$(cat "$WORK/tls-count")"; echo $((n+1)) >"$WORK/tls-count"; if [ "$n" -eq 0 ]; then echo NONE; else echo 0; fi; }; run_harness() { :; }; wait_harness() { :; }
  openssl() { :; }; chmod() { :; }
  header s8-neg; echo '0,get,err,2000,,timeout' >>"$OUT_DIR/s8-neg.csv"
  expect_failure scenario_8
}
s5_real_failures() {
  header s5
  echo '0,get,err,2000,,timeout' >>"$OUT_DIR/s5.csv"
  echo '2100,upsert,err,2000,,timeout' >>"$OUT_DIR/s5.csv"
  echo '4200,query,err,5000,,timeout' >>"$OUT_DIR/s5.csv"
  run_harness() { :; }; wait_harness() { :; }; envoy_health() { echo failed_active_hc; }
  scenario_5 || return 1
  [ "$FAIL" -eq 0 ]
}
s5_query_over_budget() {
  header s5
  echo '0,get,err,2000,,timeout' >>"$OUT_DIR/s5.csv"
  echo '2100,upsert,err,2000,,timeout' >>"$OUT_DIR/s5.csv"
  echo '4200,query,err,6000,,timeout' >>"$OUT_DIR/s5.csv"
  run_harness() { :; }; wait_harness() { :; }; envoy_health() { echo failed_active_hc; }
  expect_failure scenario_5
}
s5_endpoint_unverified() {
  envoy_health() { echo UNKNOWN; }; run_harness() { echo called >>"$WORK/damage"; }
  expect_failure scenario_5 || return 1
  [ ! -f "$WORK/damage" ]
}
s7_overlap() {
  echo 0 >"$WORK/long-running"
  docker() {
    case "$*" in
      *'SELECT RAW COUNT'*'cb-b-node-1'*) echo '{"results":[1]}' ;;
      *'SELECT RAW COUNT'*) echo '{"results":[0]}' ;;
    esac
  }
  run_harness() {
    if [ "$1" = s7-longlived ]; then echo 1 >"$WORK/long-running";
    elif [ "$1" = s7-newclient ]; then
      [ "$(cat "$WORK/long-running")" = 1 ] || { echo 'clients did not overlap' >"$WORK/no-overlap"; }
    fi
  }
  wait_harness() { if [ "$1" = s7-longlived ]; then echo 0 >"$WORK/long-running"; fi; }
  wait_observer() { echo UP; }; wait_envoy_healthy() { echo healthy; }; envoy_health() { echo failed_active_hc; }
  csv_regions() { if [ "$1" = s7-longlived ]; then echo b; else echo a; fi; }
  assert_recovery() { :; }; assert_overlap() { :; }
  scenario_7 >"$WORK/output" 2>&1 || return 1
  [ ! -f "$WORK/no-overlap" ] || { cat "$WORK/no-overlap"; return 1; }
}
node_membership_proof() {
  curl() { echo '{"nodes":[{"hostname":"cb-a-data-2.local:8091","clusterMembership":"active"}]}'; }
  docker() { echo false; }
  declare -F assert_stopped_membership >/dev/null || { echo 'node membership proof missing'; return 1; }
  expect_failure assert_stopped_membership cb-a-data-2 inactiveFailed
  FAIL=0
  assert_stopped_membership cb-a-data-2 active
}
init_failure() {
  declare -F wait_init >/dev/null || { echo 'init exit status not verified'; return 1; }
  COMPOSE_A=docker
  docker() { if [ "$1" = ps ]; then echo test-init; elif [ "$1" = inspect ]; then echo "exited 23"; fi; }
  expect_failure wait_init "$COMPOSE_A"
}
init_deadline() {
  echo 1000 >"$WORK/clock"
  date() { cat "$WORK/clock"; }
  sleep() { local now; now="$(cat "$WORK/clock")"; echo $((now+200)) >"$WORK/clock"; }
  docker() {
    case "$1" in
      ps) echo test-init ;;
      inspect) echo 'running 0' ;;
      wait) echo 0 ;;
    esac
  }
  expect_failure wait_init docker || return 1
  grep -q 'test-init.*600s' "$WORK/output" || return 1
  [ "$(cat "$WORK/clock")" -eq 1600 ]
}
init_success() {
  echo 0 >"$WORK/init-polls"
  docker() {
    case "$1" in
      ps) echo test-init ;;
      inspect)
        local n; n="$(cat "$WORK/init-polls")"; echo $((n+1)) >"$WORK/init-polls"
        if [ "$n" -eq 0 ]; then echo 'running 0'; else echo 'exited 0'; fi
        ;;
    esac
  }
  wait_init docker || return 1
  [ "$FAIL" -eq 0 ] && [ "$(cat "$WORK/init-polls")" -eq 2 ]
}
summary_offsets() {
  header offsets
  cat >>"$OUT_DIR/offsets.csv" <<'CSV'
1000,get,ok,100,a,
3000,get,err,2000,,timeout
6000,get,ok,200,b,
CSV
  echo 2500 >"$OUT_DIR/offsets.fault-ms"
  write_summary offsets || return 1
  python3 - "$OUT_DIR/offsets.summary.json" <<'PYMETRIC'
import json, sys
m = json.load(open(sys.argv[1]))
assert m['fault_epoch_ms'] == 2500
assert m['fault_offset_ms'] == 1500
assert m['first_region_b_offset_ms'] == 5200
assert m['fault_to_first_region_b_ms'] == 3700
assert m['operations']['get']['last_error_completion_offset_ms'] == 4000
PYMETRIC
  rm -f "$OUT_DIR/offsets.fault-ms"
  printf 'stdin must not become fault timestamp' | write_summary offsets || return 1
  python3 - "$OUT_DIR/offsets.summary.json" <<'PYNONE'
import json, sys
m = json.load(open(sys.argv[1]))
assert m['fault_epoch_ms'] is None and m['fault_to_first_region_b_ms'] is None
PYNONE
}
overlap_observation() {
  header old; header new
  cat >>"$OUT_DIR/old.csv" <<'CSV'
1000,get,ok,10,b,
15000,get,ok,10,b,
25000,get,ok,10,b,
CSV
  cat >>"$OUT_DIR/new.csv" <<'CSV'
12000,get,ok,10,a,
16000,query,ok,10,a,
22000,get,ok,10,a,
CSV
  assert_overlap old new 10000 || return 1
  header old
  echo '1000,get,ok,10,b,' >>"$OUT_DIR/old.csv"
  expect_failure assert_overlap old new 10000
}
sparse_terminal_success() {
  header sparse
  for t in $(seq 0 1000 180000); do
    echo "$t,get,ok,10,a," >>"$OUT_DIR/sparse.csv"
    echo "$t,query,ok,10,a," >>"$OUT_DIR/sparse.csv"
  done
  echo '0,upsert,ok,10,,' >>"$OUT_DIR/sparse.csv"
  echo '180000,upsert,ok,10,,' >>"$OUT_DIR/sparse.csv"
  expect_failure assert_recovery sparse
}
s2_pass_marker() {
  header s2
  for op in get upsert query; do
    for t in 0 5000 10000; do echo "$t,$op,ok,1,," >>"$OUT_DIR/s2.csv"; done
  done
  echo run >"$OUT_DIR/run-id"; echo run >"$OUT_DIR/s2.run-id"; echo 0 >"$OUT_DIR/s2.exit-code"
  expect_failure require_s2_baseline || return 1
  FAIL=0
  echo run >"$OUT_DIR/s2.passed-run-id"
  require_s2_baseline
}
readiness_503() {
  recover_region_a() { :; }; wait_observer() { echo UP; }
  curl() { echo '{"status":"DOWN"}'; }
  docker() { if [ "$1" = inspect ]; then echo example/image:1; fi; }
  echo 0 >"$WORK/probe-count"
  probe_cng_web() {
    local n; n="$(cat "$WORK/probe-count")"; echo $((n+1)) >"$WORK/probe-count"
    if [ "$n" -eq 0 ]; then echo 200; else echo 503; fi
  }
  capture_cng_readiness >"$WORK/output" 2>&1 || return 1
  [ "$FAIL" -eq 0 ] || return 1
  grep -q '503' "$OUT_DIR/cng-readiness-latch.txt" || return 1
  ! grep -q '/health did not detect' "$OUT_DIR/cng-readiness-latch.txt"
}
early_s7_failure() {
  echo run-fix1 >"$OUT_DIR/run-id"
  wait_observer() { echo DOWN; }; envoy_health() { echo failed_active_hc; }
  # Override only unavailable Docker effects, retain actual launch/cleanup/metrics.
  docker() {
    case "$1" in
      run)
        [[ "$*" == *'--label cng.lb.run=run-fix1'* ]] || echo unlabelled >"$WORK/unlabelled"
        touch "$WORK/owned-active"
        header s7-longlived
        echo '1000,get,ok,10,b,' >>"$OUT_DIR/s7-longlived.csv"
        ;;
      ps)
        [[ "$*" == *'label=cng.lb.run=run-fix1'* ]] || echo unscoped >"$WORK/unscoped"
        [ ! -f "$WORK/owned-active" ] || echo cng-harness-s7-longlived
        ;;
      logs)
        if [ "$2" = cng-harness-s7-longlived ]; then
          [ -f "$WORK/owned-active" ] || return 1
          echo 'partial workload log'
        fi
        ;;
      inspect) echo '{"running":true,"image":"test"}' ;;
      stop)
        if [ "$2" = cng-harness-s7-longlived ]; then
          echo stopped >"$WORK/workload-stopped"
          rm -f "$WORK/owned-active"
        fi
        ;;
      rm)
        case "$*" in
          *cng-harness-unrelated*) echo removed >"$WORK/unrelated-removed" ;;
          *cng-harness-s7-longlived*) rm -f "$WORK/owned-active" ;;
        esac
        ;;
      exec) echo '{"results":[1]}' ;;
    esac
  }
  stack_down() {
    [ ! -f "$WORK/owned-active" ] || echo active >"$WORK/active-at-teardown"
    echo teardown >"$WORK/teardown"
  }
  local status=0
  ( CLEANUP_STACK=1; trap cleanup EXIT; scenario_7 || exit $? ) >"$WORK/output" 2>&1 || status=$?
  [ "$status" -ne 0 ] || { cat "$WORK/output"; echo 'early prerequisite failure succeeded'; return 1; }
  [ ! -f "$WORK/owned-active" ] || { echo 'owned workload left active'; return 1; }
  [ ! -f "$WORK/active-at-teardown" ] || { echo 'workload active at stack teardown'; return 1; }
  [ ! -f "$WORK/unrelated-removed" ] && [ ! -f "$WORK/unlabelled" ] && [ ! -f "$WORK/unscoped" ] || return 1
  [ -f "$WORK/workload-stopped" ] && [ -f "$WORK/teardown" ] || return 1
  grep -q 'partial workload log' "$OUT_DIR/s7-longlived.harness.log" || return 1
  [ -s "$OUT_DIR/s7-longlived.harness.inspect.json" ] || return 1
  python3 - "$OUT_DIR/s7-longlived.partial.summary.json" <<'PYPARTIAL'
import json, sys
m = json.load(open(sys.argv[1]))
assert m['samples'] == 1 and m['regions'] == ['b']
PYPARTIAL
  # Manual scenario mode retains stack, but still removes its unfinished workload.
  rm -f "$WORK/teardown" "$WORK/workload-stopped"
  status=0
  ( CLEANUP_STACK=0; trap cleanup EXIT; scenario_7 || exit $? ) >"$WORK/manual-output" 2>&1 || status=$?
  [ "$status" -ne 0 ] && [ ! -f "$WORK/owned-active" ] && [ ! -f "$WORK/teardown" ]
}
failure_internal_logs() {
  docker() { echo "$*" >>"$WORK/docker-calls"; if [ "$1" = inspect ]; then echo image; fi; }
  : >"$WORK/docker-calls"
  ( CLEANUP_STACK=0; trap cleanup EXIT; exit 0 ) >"$WORK/output" 2>&1 || return 1
  if grep -Eq '^cp |^exec .*couchbase/logs' "$WORK/docker-calls"; then echo 'successful run copied internal logs'; return 1; fi
  : >"$WORK/docker-calls"
  stack_down() { echo teardown >>"$WORK/docker-calls"; }
  local status=0
  ( CLEANUP_STACK=1; trap cleanup EXIT; exit 9 ) >"$WORK/output" 2>&1 || status=$?
  [ "$status" -eq 9 ] || { echo "cleanup changed exit9 to$status"; return 1; }
  python3 - "$WORK/docker-calls" <<'PYLOGS'
import sys
calls=open(sys.argv[1]).read().splitlines()
logs=[(i,line) for i,line in enumerate(calls) if line.startswith('cp ') and '/opt/couchbase/var/lib/couchbase/logs/' in line]
assert logs, 'failure path did not preserve internal Couchbase logs'
expected={'cb-a-data-1','cb-a-data-2','cb-a-data-3','cb-a-iq-1','cb-a-iq-2','cb-b-node-1'}
assert {line.split()[1].split(':')[0] for _,line in logs} == expected, logs
allowed={'error.log','debug.log','babysitter.log','memcached.log'}
assert {line.split()[1].rsplit('/',1)[1] for _,line in logs} == allowed, logs
assert max(i for i,_ in logs) < calls.index('teardown'), calls
PYLOGS
}

failure_internal_log_directory() {
  export OUT_DIR="$WORK/collision-out"
  mkdir -p "$OUT_DIR"
  # Fresh shell retains errexit; suite conditionals would suppress it in a subshell.
  sed -n '/^cleanup() {/,/^}$/p' "$REPO/test/compose-cng/lb_e2e.sh" >"$WORK/cleanup-functions.sh"
  cat >"$WORK/diagnostic-failure.sh" <<'SH'
set -Eeuo pipefail
source "$1/test/compose-cng/lib.sh"
source "$2"
DIAGNOSTIC_WORK="$3"
docker() { echo "$*" >>"$DIAGNOSTIC_WORK/diagnostic-calls"; }
cleanup_harnesses() { echo workload-cleanup >>"$DIAGNOSTIC_WORK/diagnostic-calls"; }
stack_down() { echo teardown >>"$DIAGNOSTIC_WORK/diagnostic-calls"; }
CLEANUP_STACK=1
trap cleanup EXIT
exit 9
SH
  echo collision >"$OUT_DIR/cb-a-data-1.internal"
  : >"$WORK/diagnostic-calls"
  local status=0
  bash "$WORK/diagnostic-failure.sh" "$REPO" "$WORK/cleanup-functions.sh" "$WORK" >"$WORK/output" 2>&1 || status=$?
  [ "$status" -eq 9 ] || { cat "$WORK/output"; echo "diagnostic directory failure changed exit9 to$status"; return 1; }
  grep -q 'WARNING.*cb-a-data-1.internal' "$WORK/output" || { echo 'diagnostic directory failure lacks warning'; return 1; }
  grep -q '^workload-cleanup$' "$WORK/diagnostic-calls" && grep -q '^teardown$' "$WORK/diagnostic-calls" || { echo 'diagnostic failure skipped cleanup'; return 1; }
  grep -q '^cp cb-a-data-2:/opt/couchbase/var/lib/couchbase/logs/error.log ' "$WORK/diagnostic-calls" || { echo 'diagnostic failure stopped remaining node capture'; return 1; }
}

harness_readiness() {
  echo current >"$OUT_DIR/run-id"
  echo 1000 >"$WORK/ready-clock"
  date() { cat "$WORK/ready-clock"; }
  sleep() { local n; n="$(cat "$WORK/ready-clock")"; echo $((n+1)) >"$WORK/ready-clock"; }
  echo stale >"$OUT_DIR/gated.startup.csv"
  echo '{"run_id":"old","warmup_required":true,"ready":true,"observed_region":"a","measurement_start_epoch_ms":1}' >"$OUT_DIR/gated.ready.json"
  docker() {
    case "$1" in
      run)
        [ ! -e "$OUT_DIR/gated.ready.json" ] && [ ! -e "$OUT_DIR/gated.startup.csv" ] || echo stale >"$WORK/stale-present"
        printf '%s\n' "$*" >"$WORK/run-args"
        echo 0 >"$WORK/ready-polls"
        ;;
      inspect)
        local n; n="$(cat "$WORK/ready-polls")"; echo $((n+1)) >"$WORK/ready-polls"
        if [ "$n" = 0 ]; then
          echo '{"run_id":"foreign","warmup_required":true,"ready":true,"observed_region":"a","measurement_start_epoch_ms":1000000}' >"$OUT_DIR/gated.ready.json"
        else
          echo '{"run_id":"current","warmup_required":true,"ready":true,"observed_region":"a","measurement_start_epoch_ms":1001000}' >"$OUT_DIR/gated.ready.json"
        fi
        echo 'running 0'
        ;;
    esac
  }
  run_harness gated 20 || return 1
  [ ! -f "$WORK/stale-present" ] || return 1
  [ "$(cat "$WORK/ready-polls")" -ge 2 ] || { echo 'foreign readiness accepted'; return 1; }
  grep -q -- '-e RUN_ID=current' "$WORK/run-args" || return 1
  grep -q -- '-e READY_FILE=/out/gated.ready.json' "$WORK/run-args" || return 1
  grep -q -- '-e STARTUP_CSV=/out/gated.startup.csv' "$WORK/run-args" || return 1
}
startup_failure_prevents_fault() {
  echo current >"$OUT_DIR/run-id"
  docker() { if [ "$1" = inspect ]; then echo 'exited 17'; fi; }
  record_fault() { echo injected >"$WORK/fault-injected"; }
  expect_failure scenario_2 || return 1
  [ ! -e "$WORK/fault-injected" ] || return 1
  grep -q 'exit=17' "$WORK/output"
}
wrong_region_readiness() {
  echo current >"$OUT_DIR/run-id"
  echo 1000 >"$WORK/ready-clock"
  date() { cat "$WORK/ready-clock"; }
  sleep() { local n; n="$(cat "$WORK/ready-clock")"; echo $((n+30)) >"$WORK/ready-clock"; }
  docker() {
    if [ "$1" = inspect ]; then
      echo '{"run_id":"current","warmup_required":true,"ready":true,"observed_region":"b","measurement_start_epoch_ms":1000000}' >"$OUT_DIR/wrong.ready.json"
      echo 'running 0'
    fi
  }
  expect_failure run_harness wrong 20
}
negative_driver_policy() {
  echo current >"$OUT_DIR/run-id"
  docker() {
    case "$1" in
      run) printf '%s\n' "$*" >"$WORK/negative-args" ;;
      inspect)
        echo '{"run_id":"current","warmup_required":false,"ready":false,"observed_region":"","measurement_start_epoch_ms":1}' >"$OUT_DIR/negative.ready.json"
        echo 'running 0'
        ;;
    esac
  }
  run_harness negative 15 -e STARTUP_REQUIRED=false || return 1
  grep -q -- '-e STARTUP_REQUIRED=false' "$WORK/negative-args"
}
s5_disables_positive_warmup() {
  run_harness() { printf '%s\n' "$*" >"$WORK/s5-args"; }
  wait_harness() { :; }; assert_negative() { :; }; wait_envoy_unhealthy() { echo failed_active_hc; }
  scenario_5 || return 1
  grep -q 'STARTUP_REQUIRED=false' "$WORK/s5-args"
}
s8_disables_positive_warmup() {
  recover_region_a() { :; }; wait_envoy_healthy() { echo healthy; }; wait_observer() { echo UP; }
  openssl() { :; }; chmod() { :; }
  echo 0 >"$WORK/verify-count"
  tls_verify_code() { local n; n="$(cat "$WORK/verify-count")"; echo $((n+1)) >"$WORK/verify-count"; if [ "$n" = 0 ]; then echo 19; else echo 0; fi; }
  docker() { if [ "$1" = run ]; then printf '%s\n' "$*" >"$WORK/s8-args"; fi; }
  run_harness() { :; }; wait_harness() { :; }; assert_negative() { :; }; write_summary() { :; }
  csv_summary() { echo 'ok=0 err=5'; }; assert_recovery() { :; }; csv_regions() { echo 'a b'; }; csv_error_window_ms() { echo 0; }
  scenario_8 || return 1
  grep -q 'STARTUP_REQUIRED=false' "$WORK/s8-args"
  grep -q 'STARTUP_CSV=/out/s8-neg.startup.csv' "$WORK/s8-args"
}

dead_ready_client() {
  echo current >"$OUT_DIR/run-id"
  docker() {
    if [ "$1" = inspect ]; then
      echo '{"run_id":"current","warmup_required":true,"ready":true,"observed_region":"a","measurement_start_epoch_ms":1}' >"$OUT_DIR/dead.ready.json"
      echo 'exited 7'
    fi
  }
  expect_failure run_harness dead 20 || return 1
  [ "$(cat "$OUT_DIR/dead.exit-code")" = 7 ]
}
invalid_ready_body() {
  echo current >"$OUT_DIR/run-id"
  echo 1000 >"$WORK/ready-clock"
  date() { cat "$WORK/ready-clock"; }
  sleep() { local n; n="$(cat "$WORK/ready-clock")"; echo $((n+30)) >"$WORK/ready-clock"; }
  docker() {
    if [ "$1" = inspect ]; then
      echo '{"run_id":"current","warmup_required":true,"ready":true,"observed_region":"a","measurement_start_epoch_ms":true}' >"$OUT_DIR/body.ready.json"
      echo 'running 0'
    fi
  }
  expect_failure run_harness body 20
}

late_ready_prevents_fault() {
  echo current >"$OUT_DIR/run-id"
  echo 1000 >"$WORK/ready-clock"
  date() { cat "$WORK/ready-clock"; }
  sleep() { local n; n="$(cat "$WORK/ready-clock")"; echo $((n+91)) >"$WORK/ready-clock"; }
  docker() {
    if [ "$1" = inspect ]; then
      if [ "$(cat "$WORK/ready-clock")" -gt 1000 ]; then
        echo '{"run_id":"current","warmup_required":true,"ready":true,"observed_region":"a","measurement_start_epoch_ms":1091000}' >"$OUT_DIR/s2.ready.json"
      fi
      echo 'running 0'
    fi
  }
  record_fault() { echo injected >"$WORK/late-fault"; }
  wait_harness() { :; }; assert_recovery() { :; }; assert_stopped_membership() { :; }
  csv_regions() { echo a; }; envoy_health() { echo healthy; }; csv_error_window_ms() { echo 0; }; recover_region_a() { :; }
  expect_failure scenario_2 || return 1
  [ ! -e "$WORK/late-fault" ] || { echo 'late readiness allowed fault injection'; return 1; }
  grep -q 'readiness did not validate within 90s' "$WORK/output"
}

failed=0
for test in ${EVIDENCE_TESTS:-late_ready_prevents_fault dead_ready_client invalid_ready_body harness_readiness startup_failure_prevents_fault wrong_region_readiness negative_driver_policy s5_disables_positive_warmup s8_disables_positive_warmup failure_internal_logs failure_internal_log_directory empty_s5 crashed_harness missing_s2 permanent_write_outage terminal_recovery short_recovery exact_regions completion_gap unsafe_output failed_prerequisite missing_tls_verify s5_real_failures s5_query_over_budget s5_endpoint_unverified s7_overlap node_membership_proof init_failure init_deadline init_success summary_offsets overlap_observation sparse_terminal_success s2_pass_marker readiness_503 early_s7_failure}; do
  if ( FAIL=0; "$test" ); then echo "PASS: $test"; else echo "FAIL: $test"; failed=$((failed+1)); fi
done
[ "$failed" -eq 0 ]
