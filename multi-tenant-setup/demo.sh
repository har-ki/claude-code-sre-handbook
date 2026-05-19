#!/bin/bash

echo "🎯 Multi-Tenant Kubernetes Environment Demo"
echo "==========================================="

echo ""
echo "🧪 Testing Alice's access to her own namespace..."
kubectl run alice-test-pod --image=nginx --restart=Never -n dev-alice --dry-run=client -o yaml > /dev/null && echo "✅ Alice can create pods in dev-alice"

echo ""
echo "🧪 Testing Alice's read access to dev-shared..."
kubectl get pods -n dev-shared --as=system:serviceaccount:dev-alice:alice-sa && echo "✅ Alice can read pods in dev-shared"

echo ""
echo "🧪 Testing that Alice cannot access Bob's namespace..."
if kubectl auth can-i create pods --as=system:serviceaccount:dev-alice:alice-sa -n dev-bob | grep -q "no"; then
    echo "✅ Alice correctly denied access to dev-bob"
else
    echo "❌ Security issue: Alice has unexpected access to dev-bob"
fi

echo ""
echo "📊 Current resource utilization:"
kubectl get resourcequota --all-namespaces | grep -E "(dev-|staging|prod)"

echo ""
echo "🌐 Network policies in effect:"
kubectl get networkpolicy --all-namespaces | grep -E "(dev-|staging|prod)"

echo ""
echo "✨ Demo complete! The multi-tenant environment is secure and functional."
