#!/usr/bin/env bash
# End-to-end check: the observer runs INSIDE the compose network (so the SDK reaches
# every node), and we assert its /health/couchbase over the mapped host port.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $HERE/../deploy/compose/docker-compose.yml"
URL="http://localhost:8080/health/couchbase"

status() { curl -s "$URL" | sed -n 's/.*"status":"\([A-Z]*\)".*/\1/p'; }

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
$COMPOSE down -v >/dev/null
