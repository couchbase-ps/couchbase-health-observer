#!/usr/bin/env bash
# End-to-end check: the observer runs INSIDE the compose network (so the SDK reaches
# every node), and we assert its /health/couchbase over the mapped host port.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $HERE/../deploy/compose/docker-compose.yml"
URL="http://localhost:8080/health/couchbase"

# Global status only (top-level .status); jq avoids grabbing a per-service status.
status() { curl -s "$URL" | jq -r '.status // empty' 2>/dev/null; }

# Clean any prior run first so Docker releases its own forward of host port 8080.
$COMPOSE down --remove-orphans >/dev/null 2>&1 || true

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
