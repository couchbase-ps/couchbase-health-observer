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
    if config="$(docker network inspect --format '{{.Driver}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' "$NET" 2>/dev/null)"; then
      read -r driver subnet extra <<<"$config"
      if [ "$driver" != bridge ] || [ "$subnet" != "$SUBNET" ] || [ -n "$extra" ]; then
        echo "ERROR: existing network $NET must be bridge with subnet $SUBNET (got: $config)" >&2
        exit 1
      fi
      echo "network $NET already exists ($SUBNET)"
      exit 0
    fi
    docker network create --driver bridge --subnet "$SUBNET" "$NET" || exit $?
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
