#!/usr/bin/env bash
# One CA and ONE server certificate shared by both regions' CNG.
#
# Under L4 TLS passthrough Envoy does not decrypt, so the SDK verifies the CNG
# certificate against the name it dialled, which is the load balancer name. Both
# CNGs must therefore present a certificate valid for that one name. Sharing a
# single cert is the simplest way to guarantee it, and it is also the shape a
# real deployment needs.
#
# Idempotent: existing certs are left alone unless --force is passed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../certs"
FORCE="${1:-}"

mkdir -p "$OUT"

if [ -f "$OUT/server.crt" ] && [ "$FORCE" != "--force" ]; then
  echo "certs already present in $OUT (pass --force to regenerate)"
  exit 0
fi

rm -f "$OUT"/*.crt "$OUT"/*.key "$OUT"/*.csr "$OUT"/*.srl "$OUT"/*.cnf

echo "== CA =="
openssl req -x509 -newkey rsa:2048 -sha256 -days 730 -nodes \
  -keyout "$OUT/ca.key" -out "$OUT/ca.crt" \
  -subj "/CN=cng-lb-test-ca"

cat > "$OUT/server.cnf" <<'CNF'
[req]
distinguished_name = dn
req_extensions     = ext
prompt             = no

[dn]
CN = cng-lb

[ext]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @san

[san]
DNS.1 = cng-lb
DNS.2 = cng-a
DNS.3 = cng-b
DNS.4 = localhost
IP.1  = 127.0.0.1
IP.2  = 172.28.1.10
IP.3  = 172.28.2.10
CNF

echo "== server key and CSR =="
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/server.key" -out "$OUT/server.csr" \
  -config "$OUT/server.cnf"

echo "== sign =="
openssl x509 -req -in "$OUT/server.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server.crt" -days 730 -sha256 \
  -extensions ext -extfile "$OUT/server.cnf"

# CNG runs as a non-root user in its image and must be able to read the key.
chmod 644 "$OUT/server.key" "$OUT/server.crt" "$OUT/ca.crt"

rm -f "$OUT/server.csr"
echo "wrote $OUT/ca.crt $OUT/server.crt $OUT/server.key"
