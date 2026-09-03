#!/usr/bin/env bash
# Shared Docker network for the CNG load-balancer stack. Both region compose
# projects, Envoy and the harness attach to it, so it must exist before any
# of them come up and it must carry a fixed subnet: the Envoy config pins
# static IPs and Envoy health_check_config.address takes a literal IP, never
# a name.
#
#   net.sh up     create the network if absent
#   net.sh down   remove it
set -uo pipefail

NET="cng-lb-net"
SUBNET="172.28.0.0/16"

case "${1:-up}" in
  up)
    if docker network inspect "$NET" >/dev/null 2>&1; then
      echo "network $NET already exists"
      exit 0
    fi
    docker network create --driver bridge --subnet "$SUBNET" "$NET"
    echo "created $NET ($SUBNET)"
    ;;
  down)
    docker network rm "$NET" >/dev/null 2>&1 || true
    echo "removed $NET"
    ;;
  *)
    echo "usage: net.sh [up|down]" >&2
    exit 2
    ;;
esac
