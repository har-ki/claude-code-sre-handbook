#!/bin/bash
set -euo pipefail

# Multi-Tenant Development Environment Teardown Script
# This script removes the multi-tenant development environment

echo "🧹 Tearing down Multi-Tenant Development Environment..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl and ensure it's in your PATH."
    exit 1
fi

# Check if we can connect to the cluster
echo "📡 Checking cluster connectivity..."
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Unable to connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

echo "✅ Connected to cluster: $(kubectl config current-context)"

# Confirm deletion
echo "⚠️  WARNING: This will delete the following namespaces and all their contents:"
echo "   - dev-alice"
echo "   - dev-bob" 
echo "   - dev-charlie"
echo "   - dev-shared"
echo "   - staging"
echo "   - prod"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ $confirm != "yes" ]]; then
    echo "❌ Teardown cancelled."
    exit 0
fi

echo "🗑️  Deleting multi-tenant configuration..."
kubectl delete -f multi-tenant-dev-environment.yaml --ignore-not-found=true

# Wait for namespaces to be deleted
echo "⏳ Waiting for namespaces to be deleted..."
for ns in dev-alice dev-bob dev-charlie dev-shared staging prod; do
    echo "  🗑️  Deleting namespace: $ns"
    kubectl delete namespace $ns --ignore-not-found=true &
done

# Wait for all background deletions to complete
wait

echo ""
echo "✅ Multi-tenant development environment teardown complete!"
echo ""
echo "📋 Cleanup summary:"
echo "  - All namespaces deleted"
echo "  - All RBAC configurations removed"
echo "  - All resource quotas removed"
echo "  - All network policies removed"
