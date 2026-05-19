#!/usr/bin/env bash
# Tear down the harness-vs-model experiment.
set -euo pipefail

echo "=== Tearing down harness-vs-model experiment ==="

kind delete cluster --name harness-experiment 2>/dev/null || true
echo "[ok] cluster deleted"
