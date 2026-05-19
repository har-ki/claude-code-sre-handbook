#!/bin/bash

set -e

echo "🔍 Verifying multi-tenant Kubernetes environment..."

echo ""
echo "📁 Namespaces:"
kubectl get namespaces | grep -E "(dev-|staging|prod)"

echo ""
echo "👤 Service Accounts:"
kubectl get serviceaccounts --all-namespaces | grep -E "(alice|bob|charlie)-sa"

echo ""
echo "💾 Resource Quotas:"
kubectl get resourcequota --all-namespaces

echo ""
echo "🌐 Network Policies:"
kubectl get networkpolicy --all-namespaces

echo ""
echo "🔐 RBAC - Roles:"
kubectl get roles --all-namespaces | grep -E "(developer|readonly)"

echo ""
echo "🔗 RBAC - Role Bindings:"
kubectl get rolebindings --all-namespaces | grep -E "(alice|bob|charlie)"

echo ""
echo "📊 Testing permissions for alice-sa in dev-alice namespace:"
kubectl auth can-i create pods --as=system:serviceaccount:dev-alice:alice-sa -n dev-alice

echo ""
echo "📊 Testing read permissions for alice-sa in dev-shared namespace:"
kubectl auth can-i get pods --as=system:serviceaccount:dev-alice:alice-sa -n dev-shared

echo ""
echo "❌ Testing denied permissions for alice-sa in dev-bob namespace:"
kubectl auth can-i create pods --as=system:serviceaccount:dev-alice:alice-sa -n dev-bob

echo ""
echo "✅ Verification complete!"
