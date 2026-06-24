#!/usr/bin/env bash
# Build the linux/arm64 Lambda binary (named 'bootstrap' as required by the
# provided.al2023 runtime) into this directory, ready for terraform to zip.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../../.."
( cd "$ROOT" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -tags lambda.norpc -o "$HERE/bootstrap" ./cmd/switch-lambda )
echo "built $HERE/bootstrap"
