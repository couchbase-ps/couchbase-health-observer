#!/usr/bin/env bash
# CNG load-balancer failover scenarios.
#
#   lb_e2e.sh              run every scenario, then tear down
#   lb_e2e.sh up           bring the stack up and stop (manual demo)
#   lb_e2e.sh down         tear everything down
#   lb_e2e.sh scenario N   run one scenario against an already-up stack
#
# Most scenarios restore region-a to its full baseline before applying their
# own damage, via recover_region_a: scenarios 3, 4, 6 and 10 call it at their
# start, scenario 2 and capture_cng_readiness call it at their end (twice for
# capture_cng_readiness), so each scenario starts clean rather than
# compounding the previous one's outage. Scenario 7 is the one scenario that
# recovers region-a ON PURPOSE in the middle of its own run: it forces a
# switch, restores region-a mid-scenario, and asserts what happens to an
# already-open connection versus a brand new one.
#
# Spec: delivery vault, CNG design and plan
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

scenario_1() {
  echo "== scenario 1: baseline, both regions healthy, expect zero errors =="
  # A short settle right after stack_up: both Observers and Envoy already
  # report healthy at that point, but the cluster can still be settling for
  # a few more seconds (index/query warmup, connection pools not yet primed),
  # and a baseline started too eagerly can catch a one-off timeout on an
  # early request. This does not touch the zero-error assertion below: a
  # baseline that tolerates errors stops being a baseline.
  sleep 20
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
  echo "== scenario 5: both regions down, expect clean errors not hangs =="
  # With fail_traffic_on_panic Envoy refuses new connections outright instead
  # of routing to hosts it already knows are unhealthy, so a dead cluster is
  # not silently proxied into. What this scenario actually measures: every KV
  # operation against the fully dead pair of clusters still fails cleanly,
  # with zero successes and nothing hanging past its own 2s KV timeout. It
  # does NOT show that fail_traffic_on_panic makes errors surface faster than
  # that timeout: every recorded operation took the full 2000-2023ms to fail,
  # i.e. the timeout itself is what bounds the failure here, not Envoy's
  # response time. Distinguishing "Envoy rejected the connection fast" from
  # "the SDK's own timeout fired" would need measuring connection-establishment
  # time or the SDK's error class directly, which this harness does not do.
  echo "-- stopping region-b as well --"
  docker stop cb-b-node-1 cng-b cb-b-observer >/dev/null
  sleep 80
  run_harness s5 30
  wait_harness s5
  assert_eq "s5 zero successes" "$(csv_summary s5 | sed 's/ err=.*//; s/ok=//')" "0"
  # Every operation must fail within its own 2s KV timeout budget, not hang
  # past it. This does not show errors arrive "promptly" (well inside the
  # budget): the recorded rows sit at 2000-2023ms, i.e. right at the timeout.
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
  # file, so count errors only after it. A harness that died before ever
  # reaching the idle sleep would leave "seen" at 0 and both counts at 0,
  # which would pass the error check vacuously without exercising the idle
  # path at all: assert the idle row itself exists, and that real successes
  # were recorded after it, not just the absence of errors.
  local idle_seen post_ok post_err
  idle_seen="$(awk -F, '$2=="idle" {print 1; exit} END {}' "$OUT_DIR/s6.csv")"
  assert_eq "s6 idle marker row present" "${idle_seen:-0}" "1"
  post_ok="$(awk -F, '$2=="idle" {seen=1; next} seen && $3=="ok" {c++} END {print c+0}' \
    "$OUT_DIR/s6.csv")"
  post_err="$(awk -F, '$2=="idle" {seen=1; next} seen && $3=="err" {c++} END {print c+0}' \
    "$OUT_DIR/s6.csv")"
  assert_eq "s6 no errors after the idle gap" "$post_err" "0"
  if [ "$post_ok" -gt 0 ] 2>/dev/null; then
    echo "PASS: s6 successes recorded after the idle gap ($post_ok)"
  else
    echo "FAIL: s6 no successes recorded after the idle gap (post_ok=$post_ok)"
    FAIL=1
  fi
}

scenario_7() {
  echo "== scenario 7: recovery splits clients by connection age, not a failback =="
  # A prior run of this scenario asserted that traffic "fails back" to
  # region-a automatically once it recovers, on the theory that Envoy has no
  # latch and priority 0 reclaims traffic the moment region-a is healthy
  # again. That is true of Envoy's OWN health view, and it is true of any NEW
  # connection made after the recovery. It is not true of a connection that
  # is already established: Envoy's L4 priority routing chooses an upstream
  # only when a connection is opened, and close_connections_on_host_health_
  # failure only evicts connections when a host goes UNHEALTHY. There is no
  # equivalent eviction for a host becoming healthy again, so an existing
  # connection has no mechanism to move. Failover evicts. Failback does not.
  #
  # So recovery does not "fail back", it SPLITS: a client that connected
  # during the outage stays on region-b indefinitely, while a client that
  # connects for the first time after the recovery lands on region-a. With
  # no XDCR between the two clusters, that is application-tier split-brain,
  # not a one-shot stranded write. This scenario asserts both halves.
  local doc="stranded::$(date +%s)"

  echo "-- forcing a switch to region-b --"
  docker stop cb-a-data-2 cb-a-data-3 >/dev/null
  sleep 90
  assert_eq "s7 envoy on region-b" "$(envoy_health 172.28.1.10)" "failed_active_hc"

  echo "-- writing $doc through the LB while region-b is serving --"
  # Write the marker document directly into region-b so the identity is exact.
  docker exec cb-b-node-1 curl -fsS -u Administrator:password \
    http://cb-b-node-1:8093/query/service \
    --data-urlencode "statement=UPSERT INTO \`lbtest\` (KEY, VALUE) VALUES (\"$doc\", {\"written_in\":\"b\"})" \
    >/dev/null
  echo "-- confirming it is readable while region-b serves --"
  local before
  before="$(docker exec cb-b-node-1 curl -fsS -u Administrator:password \
    http://cb-b-node-1:8093/query/service \
    --data-urlencode "statement=SELECT RAW COUNT(*) FROM \`lbtest\` USE KEYS \"$doc\"" \
    | jq -r '.results[0]')"
  assert_eq "s7 doc present in region-b" "$before" "1"

  echo "-- starting the long-lived client BEFORE region-a recovers --"
  # This connection is opened while region-b is the only healthy priority, so
  # it connects there. The question this scenario answers is what happens to
  # THIS connection once region-a comes back, not whether a brand new
  # connection would pick region-a (it does; see the second client below).
  run_harness s7-longlived 240
  sleep 10
  echo "-- restoring region-a and waiting for Envoy to mark it healthy again --"
  docker start cb-a-data-2 cb-a-data-3 >/dev/null
  assert_eq "s7 region-a observer recovered" "$(wait_observer 8181 UP)" "UP"
  assert_eq "s7 envoy marks region-a healthy again" "$(wait_envoy_healthy 172.28.1.10)" "healthy"

  echo "-- the long-lived client's connection predates the recovery: it should NOT move --"
  wait_harness s7-longlived
  local longlived_region
  longlived_region="$(csv_regions s7-longlived)"
  assert_eq "s7 long-lived client stayed on region-b" "$longlived_region" "b"

  echo "-- a brand new client, opened only now, should land on region-a --"
  run_harness s7-newclient 30
  wait_harness s7-newclient
  local newclient_region
  newclient_region="$(csv_regions s7-newclient)"
  assert_eq "s7 new client landed on region-a" "$newclient_region" "a"

  echo "-- the point: the region-b write is still not visible in region-a --"
  local after
  after="$(docker exec cb-a-data-1 curl -fsS -u Administrator:password \
    http://cb-a-iq-1:8093/query/service \
    --data-urlencode "statement=SELECT RAW COUNT(*) FROM \`lbtest\` USE KEYS \"$doc\"" \
    | jq -r '.results[0]')"
  assert_eq "s7 doc ABSENT in region-a after recovery" "$after" "0"

  # This file ships to the customer, so it must not assert the split-brain
  # narrative unless all four readings actually back it up. The script has no
  # "set -e" and the docker-exec/jq pipelines above can fail silently (empty
  # "before"/"after"), so gate on the literal values rather than trusting that
  # a FAIL logged above by assert_eq stops anything below it from running.
  if [ "$before" = "1" ] && [ "$after" = "0" ] \
      && [ "$longlived_region" = "b" ] && [ "$newclient_region" = "a" ]; then
    {
      echo "scenario 7 evidence, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "document: $doc"
      echo "count in region-b while region-b served: $before"
      echo "count in region-a after region-a recovered: $after"
      echo
      echo "What happened: a long-lived client that connected to region-b"
      echo "during the outage stayed on region-b for the rest of its life,"
      echo "even after region-a recovered and Envoy marked it healthy again."
      echo "A brand new client, opened at that same later moment against the"
      echo "same load balancer, landed on region-a instead."
      echo
      echo "Mechanism: Envoy's L4 priority routing picks an upstream only when"
      echo "a connection is opened. close_connections_on_host_health_failure"
      echo "evicts connections when a host goes unhealthy, but there is no"
      echo "equivalent eviction when a host becomes healthy again, so an"
      echo "existing connection has no reason to move. Failover evicts."
      echo "Failback does not."
      echo
      echo "Implication: recovery does not restore one shared state, it splits"
      echo "clients by the age of their connection. Old connections keep"
      echo "writing to region-b, new connections write to region-a, and with"
      echo "no XDCR between the two clusters neither side ever sees the"
      echo "other's writes. This is application-tier split-brain, not a"
      echo "one-time stranded write, and it is why manual, coordinated"
      echo "failback is a hard requirement on whatever load balancer the customer"
      echo "deploys."
    } > "$OUT_DIR/s7-stranded.txt"
    echo "wrote $OUT_DIR/s7-stranded.txt"
  else
    {
      echo "scenario 7 evidence, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "document: $doc"
      echo
      echo "NO VERDICT: this scenario's split-brain narrative requires all"
      echo "four of: doc present in region-b while region-b served (want 1,"
      echo "got '$before'), doc absent in region-a after recovery (want 0,"
      echo "got '$after'), the long-lived client staying on region-b (want b,"
      echo "got '$longlived_region'), and the new client landing on region-a"
      echo "(want a, got '$newclient_region'). At least one did not match, so"
      echo "no split-brain claim is drawn from this run."
    } > "$OUT_DIR/s7-stranded.txt"
    echo "wrote $OUT_DIR/s7-stranded.txt (no verdict, readings did not confirm the scenario)"
  fi
}

# error_profile <csv name> -> "total err pct first_err_s last_err_s span_s"
# pct/first/last/span are meaningless when err=0, so that case prints
# "0.00 -1 -1 -1" rather than a divide-by-zero or a false span of 0.
# This lives here, not in lib.sh, because scenario 10 is the only caller and
# this file is the only one this task may touch: comparing s10's error
# profile against a same-run baseline (scenario 2) is what makes the verdict
# below defensible instead of asserted on faith.
error_profile() {
  awk -F, '
    NR>1 && $2!="idle" {
      n++
      if (start=="") start=$1
      if ($3=="err") {
        e++
        if (fe=="") fe=$1
        le=$1
      }
    }
    END {
      if (n==0) { print "0 0 0.00 -1 -1 -1"; exit }
      if (e==0) { printf "%d %d 0.00 -1 -1 -1\n", n, e; exit }
      printf "%d %d %.2f %d %d %d\n", n, e, (e/n)*100, int((fe-start)/1000), int((le-start)/1000), int((le-fe)/1000)
    }' "$OUT_DIR/$1.csv"
}

scenario_10() {
  echo "== scenario 10: kill the node --cb-host names, cluster otherwise healthy =="
  # region-a CNG is started with --cb-host=cb-a-data-1 and there is no
  # bootstrap list. Auto-failover absorbs the node loss, so the CLUSTER is fine
  # and the Observer should report UP. The open question is whether CNG
  # recovers. If it does not, this is a gateway that is dead in front of a live
  # cluster, a state nothing in the current design detects.
  #
  # Unlike every other scenario here, this one used to skip its own
  # precondition check and simply inherit whatever scenario 7 left behind.
  # routing_ok below reads $regions = "a" as proof Envoy kept routing to
  # region-a throughout, which is exactly the signal a wrong-region start
  # would silently flip. Verify the baseline explicitly, the same way
  # scenarios 3, 4 and 6 do.
  echo "-- verifying region-a is at full baseline before this scenario --"
  recover_region_a
  assert_eq "s10 envoy routing to region-a before starting" "$(wait_envoy_healthy 172.28.1.10)" "healthy"

  run_harness s10 180
  sleep 10
  echo "-- stopping cb-a-data-1, the CNG bootstrap node --"
  docker stop cb-a-data-1 >/dev/null
  sleep 90
  local obs cngweb envoyflag
  obs="$(curl -s http://localhost:8181/health/couchbase | jq -r '.status // "NONE"')"
  cngweb="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9191/health)"
  envoyflag="$(envoy_health 172.28.1.10)"
  # Self-closing evidence: if the CNG probes above ever look wrong, cng-a's
  # own recent log lines are captured right here rather than requiring a
  # separate manual repro.
  docker logs --tail 200 cng-a > "$OUT_DIR/s10-cng-logs.txt" 2>&1 || true
  wait_harness s10
  local regions summary
  regions="$(csv_regions s10)"
  summary="$(csv_summary s10)"

  echo "observer=$obs cng_web_http=$cngweb envoy=$envoyflag regions=$regions $summary"

  # The Observer must still see a healthy cluster: auto-failover absorbed it.
  assert_eq "s10 observer still UP (cluster absorbed the node)" "$obs" "UP"

  # Round 1 fix: the original verdict required s10's error count to be
  # exactly zero. Losing a data node always produces a brief KV disruption
  # (vbucket movement mid-failover) regardless of what CNG does, so that
  # branch could never fire and the scenario was guaranteed to report a
  # product gap that does not exist. Scenario 2 stops a region-a data node
  # with CNG's bootstrap node left untouched, so its error profile is the
  # baseline for "auto-failover absorbed a node, no CNG involvement". s10 is
  # judged against THAT baseline, not against zero.
  #
  # Round 2 fix: the genuine evidence for CNG's own survival is cng_ok, the
  # direct probe of its own web port, plus the error profile actually
  # comparable to s2's baseline, since that traffic ran through CNG's data
  # path. envoy_ok and routing_ok are recorded too, but per
  # deploy/compose-cng/envoy/envoy.yaml, Envoy's active health check targets
  # the OBSERVER (172.28.1.11:8080), not CNG (18098), so envoy_ok is a
  # cluster-health signal Envoy already gets from the Observer, not an
  # independent read on CNG. Citing it as proof of CNG's health would be
  # circular: a dead CNG in front of a healthy cluster is exactly the blind
  # spot this scenario exists to probe, and Envoy's own health check cannot
  # see into that blind spot at all.
  local s2_total s2_err s2_pct s2_first s2_last s2_span
  local s10_total s10_err s10_pct s10_first s10_last s10_span
  read -r s2_total s2_err s2_pct s2_first s2_last s2_span <<< "$(error_profile s2)"
  read -r s10_total s10_err s10_pct s10_first s10_last s10_span <<< "$(error_profile s10)"

  # The whole verdict below rests on comparing s10 against scenario 2's error
  # profile as a same-run baseline. If s2.csv is missing or empty (s2 never
  # ran, or crashed before writing it, e.g. this scenario run standalone via
  # "lb_e2e.sh scenario 10"), error_profile prints nothing, "read" leaves
  # every s2_* field empty, and the comparability check below would coerce
  # that emptiness to zero, making pct_max/span_max collapse to their floors
  # and comparable="yes" regardless of what s10 actually measured. Gate on
  # s2_total actually being a positive integer before trusting any of that.
  if ! [[ "$s2_total" =~ ^[0-9]+$ ]] || [ "$s2_total" -eq 0 ]; then
    echo "s10 vs s2 baseline: NO VERDICT, scenario 2's baseline is missing or empty (s2_total='$s2_total')"
    {
      echo "scenario 10 evidence, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "Stopped cb-a-data-1, the single host named by CNG --cb-host."
      echo "observer /health/couchbase : $obs"
      echo "CNG :9191/health HTTP code : $cngweb"
      echo "Envoy region-a health flag : $envoyflag"
      echo "regions served in CSV      : $regions"
      echo "harness outcome            : $summary"
      echo
      echo "NO VERDICT: this scenario's verdict requires scenario 2's error"
      echo "profile ($OUT_DIR/s2.csv) as a same-run baseline for what an"
      echo "ordinary auto-failover blip looks like with no CNG involvement."
      echo "That file is missing or empty (s2 did not run, or did not finish"
      echo "writing it), so s10's error profile has nothing to be judged"
      echo "against. Re-run scenario 2, or the full suite, before drawing a"
      echo "verdict for scenario 10."
    } > "$OUT_DIR/s10-cng-bootstrap.txt"
    echo "wrote $OUT_DIR/s10-cng-bootstrap.txt (no verdict, missing s2 baseline)"
    echo "-- restoring cb-a-data-1 (auto-failover marked it inactiveFailed, not removed) --"
    recover_region_a
    return
  fi

  local comparable
  comparable="$(awk -v s2p="$s2_pct" -v s10p="$s10_pct" -v s2s="$s2_span" -v s10s="$s10_span" 'BEGIN{
      # Generous on purpose: this is a sanity check against "wildly worse
      # than an ordinary absorbed node loss", not a tight statistical bound.
      # Floors keep a near-zero s2 baseline from making the bar impossibly
      # strict.
      pct_max = s2p * 3; if (pct_max < 1)  pct_max = 1
      span_max = s2s * 3; if (span_max < 60) span_max = 60
      if (s10p <= pct_max && s10s <= span_max) print "yes"; else print "no"
    }')"

  local cng_ok="no" envoy_ok="no" routing_ok="no"
  [ "$cngweb" = "200" ] && cng_ok="yes"
  [ "$envoyflag" = "healthy" ] && envoy_ok="yes"
  [ "$regions" = "a" ] && routing_ok="yes"

  echo "s10 vs s2 baseline: s2 err=$s2_err/$s2_total (${s2_pct}%) first=+${s2_first}s last=+${s2_last}s span=${s2_span}s"
  echo "                    s10 err=$s10_err/$s10_total (${s10_pct}%) first=+${s10_first}s last=+${s10_last}s span=${s10_span}s"
  echo "cng_ok=$cng_ok envoy_ok=$envoy_ok routing_ok=$routing_ok comparable_to_s2=$comparable"

  # The only assertion in this scenario used to be "observer still UP", which
  # says nothing about CNG's own survival. The adverse branch below (CNG did
  # NOT cleanly survive) used to just write prose to the evidence file with no
  # assertion behind it, so a real product-gap finding could ship inside a
  # green suite. Make it an assertion: any of the four signals coming back
  # "no" is a scenario failure, not merely a footnote in a text file.
  local verdict_ok="no"
  [ "$cng_ok" = "yes" ] && [ "$envoy_ok" = "yes" ] && [ "$routing_ok" = "yes" ] && [ "$comparable" = "yes" ] \
    && verdict_ok="yes"
  assert_eq "s10 CNG cleanly survived loss of its --cb-host bootstrap node" "$verdict_ok" "yes"

  {
    echo "scenario 10 evidence, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Stopped cb-a-data-1, the single host named by CNG --cb-host."
    echo "observer /health/couchbase : $obs"
    echo "CNG :9191/health HTTP code : $cngweb"
    echo "Envoy region-a health flag : $envoyflag"
    echo "regions served in CSV      : $regions"
    echo "harness outcome            : $summary"
    echo
    echo "Error profile, s10 (this scenario) vs s2 (absorbed node loss with"
    echo "CNG's bootstrap node untouched, same run, the baseline for what an"
    echo "ordinary auto-failover blip looks like with no CNG involvement):"
    echo
    # printf's "+" flag only applies to numeric conversions, so it is a
    # silent no-op on a %s field: the offsets are pre-formatted with an
    # explicit "+" here rather than relying on the flag to add one.
    printf "%-10s %8s %8s %8s %12s %12s %8s\n" "scenario" "total" "err" "err_pct" "first_err" "last_err" "span"
    printf "%-10s %8s %8s %7s%% %12s %12s %7ss\n" "s2" "$s2_total" "$s2_err" "$s2_pct" "+${s2_first}s" "+${s2_last}s" "$s2_span"
    printf "%-10s %8s %8s %7s%% %12s %12s %7ss\n" "s10" "$s10_total" "$s10_err" "$s10_pct" "+${s10_first}s" "+${s10_last}s" "$s10_span"
    echo
    if [ "$verdict_ok" = "yes" ]; then
      echo "RESULT: CNG survived the loss of its --cb-host bootstrap node."
      echo "The evidence that carries the weight: CNG's own web port kept"
      echo "answering 200 (a direct probe of CNG itself, not of the"
      echo "cluster), and real traffic through CNG's data path showed an"
      echo "app-visible error profile (err=$s10_err/$s10_total, ${s10_pct}%, spanning"
      echo "${s10_span}s) in the same range as scenario 2's ordinary"
      echo "absorbed-node-loss baseline (err=$s2_err/$s2_total, ${s2_pct}%, spanning"
      echo "${s2_span}s), which never touches CNG's bootstrap node at all. That"
      echo "means the disruption clients saw here came from the normal"
      echo "vbucket movement during auto-failover, not from the gateway."
      echo
      echo "Envoy kept routing to region-a throughout, so this scenario"
      echo "never had to exercise a switch, but that is a statement about"
      echo "routing, not about CNG's health: Envoy's active health check"
      echo "targets the Observer (172.28.1.11:8080), not CNG (18098), so"
      echo "Envoy could not have detected a dead CNG here even if one"
      echo "existed. That gap is exactly what this scenario probes, and it"
      echo "is why the verdict above rests on CNG's own web port and the"
      echo "real traffic profile, not on Envoy's view."
      echo
      echo "This closes a real risk: naming a single host with --cb-host"
      echo "does not make CNG a single point of failure when that specific"
      echo "node goes down and auto-failover absorbs it."
    else
      echo "RESULT: CNG did NOT cleanly survive the loss of its bootstrap"
      echo "node while the cluster stayed healthy. Specifics: cng_web_200=$cng_ok"
      echo "envoy_healthy=$envoy_ok stayed_on_region_a=$routing_ok"
      echo "error_profile_comparable_to_s2=$comparable. This is a gateway"
      echo "dead (or degraded beyond the ordinary failover blip) in front of"
      echo "a live cluster, and neither the Observer nor the load balancer"
      echo "detects it, because both report on the CLUSTER. It changes the"
      echo "CNG tier design and belongs in the PM conversation."
    fi
  } > "$OUT_DIR/s10-cng-bootstrap.txt"
  echo "wrote $OUT_DIR/s10-cng-bootstrap.txt"

  # Stopping cb-a-data-1 triggers auto-failover, which leaves that node
  # inactiveFailed in pools/default rather than removing it. A plain
  # "docker start" brings the container back but does not restore cluster
  # membership, so recover_region_a runs the full repair and rebalance and
  # verifies all five nodes are active before any later scenario relies on
  # region-a being at full baseline.
  echo "-- restoring cb-a-data-1 (auto-failover marked it inactiveFailed, not removed) --"
  recover_region_a
}

# tls_verify_code <cafile> -> the "Verify return code" number openssl reports
# for the leaf cert served on :18098, checked against <cafile>, or NONE if
# openssl produced no such line at all (e.g. connection failure).
#
# The harness-based negative control below (s8-neg, TLS_CA pointed at the
# wrong CA) cannot on its own tell "wrong CA rejected" from "endpoint
# unreachable": both produce identical UnambiguousTimeoutException/
# AmbiguousTimeoutException rows, the same shape scenario 5 already produces
# for a completely different reason (both regions down). This is the directly
# discriminating check: openssl's own chain verification against the bad CA
# and against the real CA, independent of the SDK's timeout-shaped errors.
tls_verify_code() {
  local cafile="$1" out
  out="$(openssl s_client -connect localhost:18098 -CAfile "$cafile" </dev/null 2>&1 \
    | sed -n 's/.*Verify return code: \([0-9]*\).*/\1/p')"
  echo "${out:-NONE}"
}

scenario_8() {
  echo "== scenario 8: repeat the switch with verified TLS, no skip-verify =="
  # Every other scenario already runs with TLS_CA set, so this is the explicit
  # negative-and-positive pair: verification ON must switch cleanly, and
  # verification against the WRONG CA must fail, proving the chain is really
  # being checked rather than quietly skipped.
  #
  # This scenario does not itself verify region-a is reachable right before
  # the negative-control run below: it relies on scenario_10's trailing
  # recover_region_a (Observer UP, Envoy healthy) having just run with no
  # disruptive step in between. If the scenario order ever changes, add that
  # check here explicitly rather than assuming it still holds.
  echo "-- negative control: verify against a CA that did not sign the cert --"
  local bad; bad="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
    -keyout "$bad/other.key" -out "$bad/other.crt" -subj "/CN=not-our-ca" 2>/dev/null
  chmod 644 "$bad/other.crt"

  echo "-- directly discriminating check: openssl against the bad CA must NOT verify --"
  local bad_code
  bad_code="$(tls_verify_code "$bad/other.crt")"
  echo "s8 openssl verify code against the bad CA: $bad_code (0 would mean it wrongly verified)"
  if [ "$bad_code" = "0" ]; then
    echo "FAIL: s8 bad CA should not verify (openssl verify code 0)"
    FAIL=1
  else
    echo "PASS: s8 bad CA fails verification (openssl verify code $bad_code)"
  fi

  docker run --rm --network cng-lb-net \
    -v "$OUT_DIR:/out" -v "$bad:/bad:ro" \
    -e CB_CONN='couchbase2://cng-lb' -e TLS_CA=/bad/other.crt \
    -e CB_BUCKET=lbtest -e RUN_SECONDS=15 -e OPS_PER_SEC=5 \
    -e OUT_CSV=/out/s8-neg.csv \
    "$HARNESS_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$bad"
  assert_eq "s8 wrong CA yields zero successes" \
    "$(csv_summary s8-neg | sed 's/ err=.*//; s/ok=//')" "0"

  echo "-- directly discriminating check: openssl against the correct CA must verify --"
  local good_code
  good_code="$(tls_verify_code "$CNG_DIR/certs/ca.crt")"
  assert_eq "s8 correct CA verifies (openssl verify code 0)" "$good_code" "0"

  echo "-- positive: correct CA, force a switch, expect a clean flip --"
  docker start cb-a-data-2 cb-a-data-3 >/dev/null 2>&1 || true
  assert_eq "s8 region-a observer healthy before the run" "$(wait_observer 8181 UP)" "UP"
  sleep 30
  docker compose -p cng-lb -f "$CNG_DIR/envoy/docker-compose.yml" up -d --force-recreate >/dev/null
  sleep 20
  run_harness s8 180
  sleep 10
  docker stop cb-a-data-2 cb-a-data-3 >/dev/null
  wait_harness s8
  assert_eq "s8 switched under verified TLS" "$(csv_regions s8)" "a b"
  local win; win="$(csv_error_window_ms s8)"
  echo "s8 error window across the switch: ${win}ms"
  assert_le "s8 recovered inside 120s" "$win" "120000"
}

probe_cng_web() { # -> HTTP code from CNG's own web port, 5 tries/15s to ride out a transient blip
  local code
  for _ in 1 2 3 4 5; do
    code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:9191/health)"
    [ "$code" != "000" ] && { echo "$code"; return 0; }
    sleep 3
  done
  echo "$code"
}

cng_diagnostics() { # dumps cng-a's running state and recent logs when a probe looks wrong
  echo "-- cng-a diagnostics --"
  docker ps -a --filter name=cng-a --format '{{.Names}} {{.Status}} {{.Ports}}' || true
  docker logs --tail 40 cng-a 2>&1 || true
}

capture_cng_readiness() {
  echo "== evidence: does CNG's /health latch healthy, or does it track the cluster? =="
  # In couchbase/stellar-gateway, /ready and its alias /health read one
  # boolean. MarkSystemHealthy() is called once at startup and
  # MarkSystemUnhealthy() has ZERO callers on master, v1.0 and v1.1 (the only
  # tags that repo has at the time of writing; there is no v1.1 tag, and no
  # v1.2.x tag either). The image actually measured below is
  # couchbase/cloud-native-gateway:1.2.1, whose exact matching source has NOT
  # been inspected: this reads its docker image tag versioning as unrelated to
  # the stellar-gateway repo's own git tags, so the caller-count claim above is
  # carried forward from master/v1.0/v1.0.1 by inference, not verified against
  # 1.2.1 itself. The measurement immediately below is what is actually
  # verified for 1.2.1; the source-reading claim is corroborating context, not
  # independently confirmed for this exact image. So /ready is being claimed
  # to answer "did startup complete once", not "is the backend reachable".
  #
  # The documentation claims the opposite: "returns HTTP 200 only when Cloud
  # Native Gateway has connected to the Couchbase cluster, and HTTP 503
  # otherwise".
  #
  # Scenario 10 already showed CNG's /health returning 200 while its
  # --cb-host bootstrap node was down, but the cluster stayed healthy there,
  # so it did not exercise the latch. This removes the whole region-a
  # cluster while leaving CNG running, which is the real test, and this is
  # the concrete answer to "why does Observer exist when CNG has a health
  # endpoint": measured evidence, not an argument from reading source alone.
  #
  # This measurement can legitimately come out either way. If CNG returns
  # 503 here against a verified healthy baseline, the latch has been fixed
  # in this image tag and the finding is void for that version: recorded as
  # such below, not adjusted to match the claim.
  #
  # A "before" reading is only meaningful against a cluster that is actually
  # up. This function is called right after scenario_8, which deliberately
  # ends with cb-a-data-2 and cb-a-data-3 stopped (its own switch test), so
  # capture_cng_readiness must not trust the ambient state: it repairs
  # region-a itself and REQUIRES the baseline to verify healthy before it
  # takes any reading. A curl HTTP code of "000" means the connection never
  # completed, i.e. no response was received. That is not a data point about
  # CNG being unhealthy, it means the probe did not reach CNG at all, so it
  # is never treated as a 503 or as any other real answer: if either the
  # baseline or the post-outage probe comes back "000" (or anything besides
  # 200/503), this writes NO verdict rather than an inferred one.
  local cng_image before_obs before_cng after_obs after_cng

  echo "-- restoring region-a to a known-good baseline before measuring (scenario 8 leaves it degraded) --"
  recover_region_a
  cng_image="$(docker inspect --format='{{.Config.Image}}' cng-a 2>/dev/null || echo unknown)"

  echo "-- verifying the baseline: Observer UP and CNG /health 200 before taking any 'before' reading --"
  before_obs="$(wait_observer 8181 UP)"
  before_cng="$(probe_cng_web)"
  echo "baseline: observer=$before_obs cng_web_http=$before_cng cng_image=$cng_image"

  if [ "$before_obs" != "UP" ] || [ "$before_cng" != "200" ]; then
    echo "FAIL: capture_cng_readiness: could not establish a healthy baseline (observer=$before_obs cng=$before_cng)"
    FAIL=1
    cng_diagnostics
    {
      echo "CNG readiness latch, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "CNG image tested: $cng_image"
      echo
      echo "MEASUREMENT FAILED: no healthy baseline could be established"
      echo "before taking region-a's cluster down, so no verdict is drawn"
      echo "either way in this file."
      echo "observer baseline reading   : $before_obs (wanted UP)"
      echo "CNG :9191/health baseline   : $before_cng (wanted 200)"
      echo
      echo "A code of 000 means the probe never received a response from"
      echo "CNG (connection failure or timeout), not that CNG answered 503."
      echo
      echo "Re-run 'lb_e2e.sh readiness' once region-a is confirmed healthy."
    } > "$OUT_DIR/cng-readiness-latch.txt"
    echo "wrote $OUT_DIR/cng-readiness-latch.txt (no verdict, baseline failed)"
    return 1
  fi

  echo "-- taking region-a's cluster down while leaving CNG running (image: $cng_image) --"
  docker stop $REGION_A_NODES >/dev/null
  sleep 60

  after_obs="$(curl -s http://localhost:8181/health/couchbase | jq -r '.status // "NONE"')"
  after_cng="$(probe_cng_web)"
  echo "observer=$after_obs cng_web_http=$after_cng cng_image=$cng_image"

  assert_eq "observer reports DOWN with the cluster gone" "$after_obs" "DOWN"

  if [ "$after_cng" != "200" ] && [ "$after_cng" != "503" ]; then
    echo "FAIL: capture_cng_readiness: CNG /health returned '$after_cng' after the cluster was stopped, neither 200 nor 503"
    FAIL=1
    cng_diagnostics
    {
      echo "CNG readiness latch, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "CNG image tested: $cng_image"
      echo
      printf "%-34s %-12s %-12s\n" "" "cluster up" "cluster gone"
      printf "%-34s %-12s %-12s\n" "Observer /health/couchbase" "$before_obs" "$after_obs"
      printf "%-34s %-12s %-12s\n" "CNG :9191/health HTTP code" "$before_cng" "$after_cng"
      echo
      echo "MEASUREMENT FAILED after the cluster was taken down: CNG's"
      echo "/health returned '$after_cng', which is neither 200 nor 503. That"
      echo "is not evidence about the latch either way, a non-HTTP result"
      echo "(such as 000) means the probe did not get a real response from"
      echo "CNG. No verdict is drawn from this run."
    } > "$OUT_DIR/cng-readiness-latch.txt"
    echo "wrote $OUT_DIR/cng-readiness-latch.txt (no verdict, invalid measurement)"
    recover_region_a
    return 1
  fi

  assert_eq "CNG /health still reports 200 with the cluster gone (latch; a 503 here means the finding is void for $cng_image)" "$after_cng" "200"

  {
    echo "CNG readiness latch, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "CNG image tested: $cng_image"
    echo
    printf "%-34s %-12s %-12s\n" "" "cluster up" "cluster gone"
    printf "%-34s %-12s %-12s\n" "Observer /health/couchbase" "$before_obs" "$after_obs"
    printf "%-34s %-12s %-12s\n" "CNG :9191/health HTTP code" "$before_cng" "$after_cng"
    echo
    # The verdict is gated on BOTH readings, not on after_cng alone: after_obs
    # is asserted separately above with assert_eq, but an assertion failure
    # does not stop this file from being written, so without this gate a
    # reader of the artifact alone could see a confident "FINDING HOLDS"
    # sitting next to a table row that is not actually DOWN.
    if [ "$after_obs" = "DOWN" ] && [ "$after_cng" = "200" ]; then
      echo "FINDING HOLDS for $cng_image: CNG's own health endpoint cannot"
      echo "report unhealthy, MEASURED against this exact image."
      echo
      echo "Proposed mechanism, NOT independently verified against the"
      echo "$cng_image source: in couchbase/stellar-gateway, /ready and its"
      echo "alias /health read one boolean; MarkSystemHealthy() is called"
      echo "once at startup and MarkSystemUnhealthy() has zero callers on"
      echo "master, v1.0 and v1.0.1 (the only tags that repo carries at the"
      echo "time of writing). The stellar-gateway source matching the"
      echo "$cng_image docker tag specifically was not inspected, and the"
      echo "gRPC grpc.health.v1.Health/Check claim below is inferred from"
      echo "those branches, not confirmed for this image:"
      echo "the service is stamped SERVING at construction and never updated."
      echo
      echo "The documentation states the opposite: /ready 'returns HTTP 200"
      echo "only when Cloud Native Gateway has connected to the Couchbase"
      echo "cluster, and HTTP 503 otherwise'."
      echo
      echo "Consequence: a customer who configures /ready or /health as"
      echo "their load balancer health check gets a check that can never"
      echo "fail, even with the entire backend cluster gone. This is the"
      echo "justification for Observer, and the basis for asking that CNG"
      echo "consume Observer health probes directly."
    else
      echo "NO VERDICT for $cng_image: the finding requires the Observer to"
      echo "read DOWN and CNG to read 200 with the cluster gone; this run"
      echo "saw observer=$after_obs cng=$after_cng."
      if [ "$after_cng" != "200" ]; then
        echo
        echo "CNG's /health returned $after_cng, not 200, with the whole"
        echo "region-a cluster gone against a verified healthy baseline"
        echo "(observer UP, CNG 200 before the outage). The latch described"
        echo "above (MarkSystemUnhealthy has zero callers) does not"
        echo "reproduce on this image. Treat the design note's claim that"
        echo "/ready and /health never go unhealthy as VOID for $cng_image:"
        echo "it needs correcting, not repeating, and the stellar-gateway"
        echo "source for the tag matching this image should be re-checked"
        echo "before restating the claim for any other version."
      fi
      if [ "$after_obs" != "DOWN" ]; then
        echo
        echo "The Observer did not read DOWN either (got $after_obs), so"
        echo "this run does not cleanly isolate CNG's behaviour from the"
        echo "cluster's own state and should not be cited either way."
      fi
    fi
  } > "$OUT_DIR/cng-readiness-latch.txt"
  echo "wrote $OUT_DIR/cng-readiness-latch.txt"

  recover_region_a
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
    # stack_up's own baseline assertions (both Observers, both region markers,
    # both Envoy priorities) can fail without stopping the script, since
    # assert_eq only sets FAIL rather than exiting. Without this check, a
    # broken stack still ran all nine scenarios and produced all three
    # evidence files against a stack that was never actually healthy.
    if [ "$FAIL" -ne 0 ]; then
      echo "== stack_up FAILED baseline checks, aborting before running scenarios =="
      exit "$FAIL"
    fi
    scenario_1
    scenario_2
    scenario_3
    scenario_4
    scenario_5
    scenario_6
    scenario_7
    scenario_10
    scenario_8
    capture_cng_readiness
    if [ "$FAIL" -eq 0 ]; then echo "== ALL SCENARIOS PASSED =="; else echo "== SCENARIOS FAILED =="; fi
    exit "$FAIL"
    ;;
  *) echo "usage: lb_e2e.sh [up|down|test|scenario N]" >&2; exit 2 ;;
esac
