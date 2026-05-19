#!/bin/bash

set -e

echo "🚀 Deploying multi-tenant Kubernetes environment..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl first."
    exit 1
fi

# Check cluster connectivity
echo "🔍 Checking cluster connectivity..."
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

echo "✅ Connected to cluster"

# Deploy namespaces first
echo "📁 Creating namespaces..."
kubectl apply -f 01-namespaces.yaml

# Wait a moment for namespaces to be created
sleep 2

# Deploy service accounts
echo "👤 Creating service accounts..."
kubectl apply -f 02-service-accounts.yaml

# Deploy RBAC configuration
echo "🔐 Configuring RBAC..."
kubectl apply -f 03-rbac.yaml

# Deploy resource quotas
echo "💾 Setting resource quotas..."
kubectl apply -f 04-resource-quotas.yaml

# Deploy network policies
echo "🌐 Applying network policies..."
kubectl apply -f 05-network-policies.yaml

echo ""
echo "✅ Multi-tenant environment deployed successfully!"
echo ""
echo "📊 Summary:"
echo "  - Namespaces: dev-alice, dev-bob, dev-charlie, dev-shared, staging, prod"
echo "  - Service accounts: alice-sa, bob-sa, charlie-sa"
echo "  - RBAC: Full access to own namespaces, read-only to dev-shared"
echo "  - Resource quotas: Applied to all namespaces"
echo "  - Network policies: Proper isolation between environments"
echo ""
echo "🔍 To verify the setup:"
echo "  kubectl get namespaces"
echo "  kubectl get resourcequota --all-namespaces"
echo "  kubectl get networkpolicy --all-namespaces"
echo "  kubectl get serviceaccounts --all-namespaces | grep -E '(alice|bob|charlie)-sa'"
