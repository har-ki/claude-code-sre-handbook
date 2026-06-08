#!/usr/bin/env bash
# Teardown for config-env-from-configmap scenario.

set -euo pipefail

echo "=== Config Env From ConfigMap Teardown ==="
kubectl delete namespace color-size-settings --ignore-errors
echo "[ok] namespace color-size-settings deleted"
