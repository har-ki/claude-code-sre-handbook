#!/bin/bash
#
# Multi-Tenant Development Environment Setup Script
# Creates namespaces, service accounts, RBAC, resource quotas,
# and network policies for a secure multi-tenant development cluster.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

echo "=== Multi-Tenant Development Environment Setup ==="
echo ""

# --- Pre-flight checks ---
echo "Checking prerequisites..."

if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found in PATH. Please install kubectl."
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster. Check your kubeconfig."
    exit 1
fi

CLUSTER=$(kubectl config current-context 2>/dev/null || echo "unknown")
echo "Cluster: ${CLUSTER}"
echo ""

# --- Apply manifests in order ---
echo "Applying manifests in order..."
echo ""

declare -A MANIFEST_LABELS=(
    ["01-namespaces.yaml"]="Namespaces"
    ["02-service-accounts.yaml"]="Service Accounts"
    ["03-rbac.yaml"]="RBAC (Roles & Bindings)"
    ["04-resource-quotas.yaml"]="Resource Quotas"
    ["05-network-policies.yaml"]="Network Policies"
)

for manifest in "${MANIFEST_LABELS[@]}"; do
    # Extract label from associative array
    label=""
    for key in "${!MANIFEST_LABELS[@]}"; do
        if [[ "${MANIFEST_LABELS[$key]}" == "$manifest" ]]; then
            label="${MANIFEST_LABELS[$key]}"
            break
        fi
    done
done

for manifest in 01-namespaces.yaml 02-service-accounts.yaml 03-rbac.yaml 04-resource-quotas.yaml 05-network-policies.yaml; do
    filepath="${MANIFESTS_DIR}/${manifest}"
    if [[ ! -f "$filepath" ]]; then
        echo "ERROR: Missing manifest: ${filepath}"
        exit 1
    fi

    echo "  Applying ${manifest}..."
    kubectl apply -f "$filepath" --record
done

echo ""

# --- Wait for namespaces ---
echo "Waiting for namespaces to be ready..."
for ns in dev-alice dev-bob dev-charlie dev-shared staging prod; do
    kubectl wait --for=condition=Ready namespace/${ns} --timeout=60s 2>/dev/null || true
done
echo ""

# --- Verify setup ---
echo "=== Verification ==="
echo ""

echo "Namespaces:"
kubectl get namespaces -l 'environment in (development,staging,production)' --show-labels
echo ""

echo "Service Accounts:"
kubectl get serviceaccounts -n dev-alice -l owner=alice
kubectl get serviceaccounts -n dev-bob -l owner=bob
kubectl get serviceaccounts -n dev-charlie -l owner=charlie
echo ""

echo "Resource Quotas:"
kubectl get resourcequotas -A
echo ""

echo "Network Policies:"
kubectl get networkpolicies -A
echo ""

echo "RBAC Summary:"
for ns in dev-alice dev-bob dev-charlie dev-shared staging prod; do
    echo "  ${ns}:"
    kubectl get rolebindings -n "${ns}" --no-headers 2>/dev/null | awk '{print "    " $1}'
done
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  - Test access:          kubectl auth can-i --list --as=system:serviceaccount:dev-alice:alice-sa -n dev-alice"
echo "  - Cross-tenant test:    kubectl auth can-i --list --as=system:serviceaccount:dev-alice:alice-sa -n dev-bob (should be empty)"
echo "  - Shared namespace:     kubectl auth can-i --list --as=system:serviceaccount:dev-alice:alice-sa -n dev-shared"
echo "  - View pods:            kubectl get pods -A"
echo "  - View events:          kubectl get events -A --sort-by='.lastTimestamp'"
