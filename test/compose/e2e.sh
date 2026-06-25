#!/usr/bin/env bash
# Compose stack: automated e2e check, or a manual demo driver.
#
#   e2e.sh            full automated e2e (build, up, kill a node, assert auto-failover, teardown)
#   e2e.sh up         bring the stack up and wait until healthy, then STOP (no kill, no teardown)
#   e2e.sh down       tear the stack down (containers + volumes)
#
# The observer runs INSIDE the compose network (so the SDK reaches every node), and we
# assert its /health/couchbase over the mapped host port.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $HERE/../../deploy/compose/docker-compose.yml"
URL="http://localhost:8080/health/couchbase"
MODE="${1:-test}"

# Global status only (top-level .status); jq avoids grabbing a per-service status.
status() { curl -s "$URL" | jq -r '.status // empty' 2>/dev/null; }

teardown() { $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true; }

cheatsheet() {
  cat <<'EOF'

================= COMPOSE DEMO READY =================
Couchbase UI : http://localhost:8091        (Administrator / password)
Observer API : curl -s http://localhost:8080/health/couchbase | jq
Observer logs: docker logs -f cb-observer
Kill a node  : docker stop cb-data-2        (KV goes DOWN, then auto-failover -> UP)
Restore node : docker start cb-data-2
Teardown     : test/compose/e2e.sh down

Note: this is a SINGLE Couchbase cluster. The demo shows the observer detecting a
node loss (DOWN) and Couchbase auto-failover absorbing it (back to UP). There is no
region switch here -- that is the kind and AWS demos.
=====================================================
EOF
}

if [[ "$MODE" == "down" ]]; then
  echo "== tearing down compose =="; teardown; echo "done"; exit 0
fi

# Clean any prior run first so Docker releases its own forward of host port 8080.
teardown

# Guard: with our stack down, ANY remaining listener on host 8080 is a stray host
# process (e.g. a leftover `go run ./cmd/svchealthcheck` bound to localhost, which
# cannot reach the internal node addresses and would answer the curls with DOWN).
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "FAIL: a non-Docker process is listening on host port 8080 (kill it first):"
  lsof -nP -iTCP:8080 -sTCP:LISTEN | grep -v COMMAND
  exit 1
fi

echo "== bringing up cluster + observer (build) =="
$COMPOSE up -d --build
echo "== waiting for cluster init + observer (up to ~150s) =="
for i in $(seq 1 30); do
  s="$(status || true)"
  echo "  t=$((i*5))s status=${s:-<none>}"
  [ "$s" = "UP" ] && break
  sleep 5
done
[ "$(status)" = "UP" ] || { echo "FAIL: expected UP baseline"; curl -s "$URL"; exit 1; }
echo "baseline: $(curl -s "$URL")"

# Manual demo: stack is up and healthy; hand control to the presenter.
if [[ "$MODE" == "up" ]]; then cheatsheet; exit 0; fi

# ---- automated test path (default, used by CI) ----
echo "== stop a data node: kv should go DOWN (endpoint unreachable, not yet failed over) =="
docker stop cb-data-2 >/dev/null
sleep 10
echo "after kill: $(curl -s "$URL")"
[ "$(status)" = "DOWN" ] || { echo "FAIL: expected DOWN after node kill"; exit 1; }

echo "== wait for auto-failover (timeout 30s) to absorb it: back to UP =="
for i in $(seq 1 12); do
  s="$(status)"; echo "  t=$((i*5))s status=$s"
  [ "$s" = "UP" ] && break
  sleep 5
done
[ "$(status)" = "UP" ] || { echo "FAIL: expected UP after auto-failover"; exit 1; }

echo "PASS"
teardown
