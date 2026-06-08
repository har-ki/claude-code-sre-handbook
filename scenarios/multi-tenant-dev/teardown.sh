#!/bin/bash
#
# Multi-Tenant Development Environment Teardown Script
# Removes all namespaces, which cascades to delete all resources.
#
set -euo pipefail

echo "=== Multi-Tenant Development Environment Teardown ==="
echo ""

# --- Pre-flight checks ---
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found in PATH."
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster."
    exit 1
fi

echo "Deleting all multi-tenant namespaces..."
echo ""

# Delete namespaces (order matters: dev-shared last to avoid cascade issues)
NAMESPACES=(prod staging dev-charlie dev-bob dev-alice dev-shared)

for ns in "${NAMESPACES[@]}"; do
    echo "  Deleting namespace: ${ns}"
    kubectl delete namespace "${ns}" --timeout=60s 2>/dev/null || true
done

echo ""
echo "Waiting for namespaces to be terminated..."
for ns in "${NAMESPACES[@]}"; do
    kubectl wait --namespace="${ns}" --for=delete namespace "${ns}" --timeout=120s 2>/dev/null || true
done
echo ""

echo "=== Teardown Complete ==="
echo ""
echo "Remaining namespaces:"
kubectl get namespaces --no-headers | grep -v "^\s*\(kube-system\|kube-public\|kube-flannel\)" || echo "  (none outside system namespaces)"
