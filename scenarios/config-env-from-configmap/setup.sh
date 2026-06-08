#!/usr/bin/env bash
# Setup script for config-env-from-configmap scenario.
# Creates namespace, two ConfigMaps, and an nginx:alpine pod that consumes
# a ConfigMap key as an env var and mounts another as a volume.
#
# Idempotent — safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Config Env From ConfigMap Setup ==="

# ── 1. Apply manifests ───────────────────────────────────────────────────────

echo "[..] applying manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/configmaps.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/pod.yaml"
echo "[ok] manifests applied"

# ── 2. Wait for pod to be ready ──────────────────────────────────────────────

echo "[..] waiting for pod1 to be ready (up to 60s)..."
kubectl wait --for=condition=Ready pod/pod1 -n color-size-settings --timeout=60s
echo "[ok] pod1 ready"

# ── 3. Verify ────────────────────────────────────────────────────────────────

echo ""
echo "=== Scenario Status ==="
echo ""
kubectl get pods -n color-size-settings
echo ""
echo "--- ConfigMaps ---"
kubectl get configmaps -n color-size-settings
echo ""
echo "--- Pod env (COLOR) ---"
kubectl exec pod1 -n color-size-settings -- sh -c 'echo $COLOR'
echo ""
echo "--- Mounted ConfigMap keys ---"
kubectl exec pod1 -n color-size-settings -- sh -c 'ls /etc/sizes/ && cat /etc/sizes/size'
echo ""

echo "[ok] scenario complete"
