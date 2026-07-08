#!/usr/bin/env bash
# Compose TLS e2e: proves --tls-cert-path and --tls-skip-verify let the observer
# talk to Couchbase over couchbases://, and that WITHOUT either flag TLS
# verification fails (negative control). Reuses the shared 5-node compose stack.
#
#   tls_e2e.sh          full automated run (up, 3 assertions, teardown)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
COMPOSE="docker compose -f $REPO/deploy/compose/docker-compose.yml"
IMAGE="cb-health-observer:tls-e2e"
CERTDIR=""
CERT=""
FAIL=0

teardown() {
  docker rm -f cb-observer-tls >/dev/null 2>&1 || true
  $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
  [ -n "$CERTDIR" ] && rm -rf "$CERTDIR" 2>/dev/null || true
}
trap teardown EXIT

echo "== up =="
teardown   # clean any prior run BEFORE creating this run's temp dir
$COMPOSE up -d
# Temp dir for the fetched CA. Created after the initial teardown so that
# teardown (which removes $CERTDIR) can never delete it out from under us.
CERTDIR="$(mktemp -d)"
CERT="$CERTDIR/ca.pem"
# Build the observer image under the tag the one-off TLS containers run below.
# (compose builds its own "compose-observer"; the docker run calls need this tag.)
docker build -t "$IMAGE" "$REPO"

# Wait until the cluster is up AND its CA is retrievable. The CA endpoint can lag
# /pools/default just after provisioning, so retry the fetch itself rather than
# fetching once (travel-sample load takes ~90s but the CA is ready well before that).
echo "== waiting for cluster init + CA =="
for i in $(seq 1 60); do
  if curl -fsu Administrator:password http://localhost:8091/pools/default/certificate 2>/dev/null > "$CERT" \
     && grep -q "BEGIN CERTIFICATE" "$CERT"; then
    break
  fi
  sleep 5
done
if ! grep -q "BEGIN CERTIFICATE" "$CERT"; then
  echo "FAIL: could not fetch cluster CA within window"; exit 1
fi

NET="$(docker inspect cb-data-1 -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')"

# run_observer <name> <hostport> <extra args...> ; leaves container running
run_observer() {
  local name="$1" port="$2"; shift 2
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --network "$NET" -p "$port:$port" \
    -v "$CERT:/ca.pem:ro" "$IMAGE" \
    --conn=couchbases://cb-data-1.local --bucket=travel-sample \
    --user=Administrator --pass=password --critical=kv --addr=":$port" "$@" >/dev/null
}

# wait_status <hostport> <want> -> polls until the observer reports <want>,
# printing it; on timeout prints the last status seen (NONE if never answered).
# A freshly-started observer can briefly report DOWN while the cluster/bucket
# settles, so positive cases (want=UP) must wait through that transient rather
# than accept the first non-empty status. The negative case (want=DOWN) returns
# as soon as DOWN is observed. Window covers CI cluster+bucket settle (~180s).
wait_status() {
  local port="$1" want="$2" last="NONE"
  for i in $(seq 1 36); do
    last="$(curl -s "http://localhost:$port/health/couchbase" | jq -r '.status // empty' 2>/dev/null)"
    [ "$last" = "$want" ] && { echo "$want"; return 0; }
    sleep 5
  done
  echo "$last"
}

assert() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1 ($2)"
  else
    echo "FAIL: $1 (got=$2 want=$3)"; FAIL=1
    echo "---- cb-observer-tls logs ----"; docker logs cb-observer-tls 2>&1 | tail -30 || true
  fi
}

echo "== case 1: --tls-cert-path -> UP =="
run_observer cb-observer-tls 8082 --tls-cert-path=/ca.pem
assert "cert-path" "$(wait_status 8082 UP)" "UP"
docker rm -f cb-observer-tls >/dev/null 2>&1 || true

echo "== case 2: --tls-skip-verify -> UP =="
run_observer cb-observer-tls 8083 --tls-skip-verify
assert "skip-verify" "$(wait_status 8083 UP)" "UP"
docker rm -f cb-observer-tls >/dev/null 2>&1 || true

echo "== case 3 (negative): no TLS flags -> DOWN =="
run_observer cb-observer-tls 8084
assert "no-flags-verify-fails" "$(wait_status 8084 DOWN)" "DOWN"
docker rm -f cb-observer-tls >/dev/null 2>&1 || true

if [ "$FAIL" -eq 0 ]; then echo "== ALL TLS E2E PASSED =="; else echo "== TLS E2E FAILED =="; fi
exit "$FAIL"
