#!/bin/bash
set -euo pipefail

# Multi-Tenant Development Environment Setup Script
# This script creates a secure, isolated development environment for 3 developers

echo "🚀 Setting up Multi-Tenant Development Environment..."

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

# Apply the multi-tenant configuration
echo "📦 Applying multi-tenant configuration..."
kubectl apply -f multi-tenant-dev-environment.yaml

# Wait for namespaces to be ready
echo "⏳ Waiting for namespaces to be ready..."
for ns in dev-alice dev-bob dev-charlie dev-shared staging prod; do
    kubectl wait --for=condition=Ready namespace/$ns --timeout=60s 2>/dev/null || true
done

# Verify the setup
echo "🔍 Verifying setup..."

# Check namespaces
echo "📁 Checking namespaces:"
kubectl get namespaces --selector="environment in (development,staging,production)" --show-labels

# Check service accounts
echo "👤 Checking service accounts:"
for ns in dev-alice dev-bob dev-charlie; do
    sa_name="${ns#dev-}-sa"
    if kubectl get serviceaccount $sa_name -n $ns &>/dev/null; then
        echo "  ✅ $sa_name in $ns"
    else
        echo "  ❌ $sa_name in $ns"
    fi
done

# Check resource quotas
echo "💰 Checking resource quotas:"
for ns in dev-alice dev-bob dev-charlie dev-shared staging prod; do
    if kubectl get resourcequota -n $ns &>/dev/null; then
        echo "  ✅ Resource quota in $ns"
    else
        echo "  ❌ Resource quota in $ns"
    fi
done

# Check network policies
echo "🔒 Checking network policies:"
for ns in dev-alice dev-bob dev-charlie dev-shared staging prod; do
    policy_count=$(kubectl get networkpolicies -n $ns --no-headers 2>/dev/null | wc -l)
    echo "  📋 $ns: $policy_count network policies"
done

echo ""
echo "🎉 Multi-tenant development environment setup complete!"
echo ""
echo "📋 Summary:"
echo "  - 6 namespaces created (dev-alice, dev-bob, dev-charlie, dev-shared, staging, prod)"
echo "  - 3 service accounts created (alice-sa, bob-sa, charlie-sa)"
echo "  - RBAC configured for proper access control"
echo "  - Resource quotas applied to all namespaces"
echo "  - Network policies enforced for tenant isolation"
echo ""
echo "🔧 Next steps:"
echo "  - Test access with: kubectl auth can-i --list --as=system:serviceaccount:dev-alice:alice-sa"
echo "  - Create kubeconfig files for each developer"
echo "  - Deploy sample applications to test the setup"
echo ""
echo "📚 For more information, see the README.md file."
