#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# Dependency pinned in a disposable test environment, never in system Python.
PYTHON="${DEMO_PYTHON:-$ROOT/.demo-aws/tools/venv/bin/python}"
if [ ! -x "$PYTHON" ]; then
  python3 -m venv "$ROOT/.demo-aws/tools/venv"
  "$ROOT/.demo-aws/tools/venv/bin/pip" -q install PyYAML==6.0.3
fi
"$PYTHON" "$ROOT/test/aws/cng-demo/render_test.py"
helm lint "$ROOT/deploy/aws/cng-demo/chart"
