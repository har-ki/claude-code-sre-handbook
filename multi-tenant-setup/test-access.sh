#!/bin/bash
set -euo pipefail

# Multi-Tenant RBAC Testing Script
# This script tests the access controls and permissions for each developer

echo "🔐 Testing Multi-Tenant RBAC Permissions..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please install kubectl and ensure it's in your PATH."
    exit 1
fi

# Function to test permissions for a service account
test_permissions() {
    local sa_name=$1
    local sa_namespace=$2
    local test_namespace=$3
    local expected_access=$4
    
    echo "👤 Testing $sa_name access to namespace $test_namespace (expected: $expected_access)"
    
    # Test basic resource access
    local can_list_pods=$(kubectl auth can-i list pods --as=system:serviceaccount:$sa_namespace:$sa_name -n $test_namespace 2>/dev/null && echo "✅" || echo "❌")
    local can_create_pods=$(kubectl auth can-i create pods --as=system:serviceaccount:$sa_namespace:$sa_name -n $test_namespace 2>/dev/null && echo "✅" || echo "❌")
    local can_delete_pods=$(kubectl auth can-i delete pods --as=system:serviceaccount:$sa_namespace:$sa_name -n $test_namespace 2>/dev/null && echo "✅" || echo "❌")
    
    echo "  📋 List pods: $can_list_pods"
    echo "  ➕ Create pods: $can_create_pods"
    echo "  🗑️  Delete pods: $can_delete_pods"
    echo ""
}

# Function to test network connectivity
test_network() {
    local from_ns=$1
    local to_ns=$2
    local expected_result=$3
    
    echo "🌐 Testing network access from $from_ns to $to_ns (expected: $expected_result)"
    
    # Deploy test pods if they don't exist
    kubectl run test-pod-$from_ns --image=busybox --restart=Never -n $from_ns --command -- sleep 3600 2>/dev/null || true
    kubectl run test-pod-$to_ns --image=busybox --restart=Never -n $to_ns --command -- sleep 3600 2>/dev/null || true
    
    # Wait for pods to be ready
    kubectl wait --for=condition=Ready pod/test-pod-$from_ns -n $from_ns --timeout=30s 2>/dev/null || echo "  ⚠️  Test pod not ready in $from_ns"
    kubectl wait --for=condition=Ready pod/test-pod-$to_ns -n $to_ns --timeout=30s 2>/dev/null || echo "  ⚠️  Test pod not ready in $to_ns"
    
    # Test connectivity (with timeout)
    local connectivity_result=""
    if timeout 10 kubectl exec test-pod-$from_ns -n $from_ns -- nc -z test-pod-$to_ns.$to_ns.svc.cluster.local 80 2>/dev/null; then
        connectivity_result="✅ Connected"
    else
        connectivity_result="❌ Blocked"
    fi
    
    echo "  🔗 Connectivity: $connectivity_result"
    echo ""
}

echo "🚀 Starting RBAC permission tests..."
echo ""

# Test Alice's permissions
echo "==== Testing Alice's Access ===="
test_permissions "alice-sa" "dev-alice" "dev-alice" "FULL"
test_permissions "alice-sa" "dev-alice" "dev-bob" "NONE"
test_permissions "alice-sa" "dev-alice" "dev-charlie" "NONE"
test_permissions "alice-sa" "dev-alice" "dev-shared" "READ-ONLY"
test_permissions "alice-sa" "dev-alice" "staging" "NONE"
test_permissions "alice-sa" "dev-alice" "prod" "NONE"

# Test Bob's permissions
echo "==== Testing Bob's Access ===="
test_permissions "bob-sa" "dev-bob" "dev-alice" "NONE"
test_permissions "bob-sa" "dev-bob" "dev-bob" "FULL"
test_permissions "bob-sa" "dev-bob" "dev-charlie" "NONE"
test_permissions "bob-sa" "dev-bob" "dev-shared" "READ-ONLY"
test_permissions "bob-sa" "dev-bob" "staging" "NONE"
test_permissions "bob-sa" "dev-bob" "prod" "NONE"

# Test Charlie's permissions
echo "==== Testing Charlie's Access ===="
test_permissions "charlie-sa" "dev-charlie" "dev-alice" "NONE"
test_permissions "charlie-sa" "dev-charlie" "dev-bob" "NONE"
test_permissions "charlie-sa" "dev-charlie" "dev-charlie" "FULL"
test_permissions "charlie-sa" "dev-charlie" "dev-shared" "READ-ONLY"
test_permissions "charlie-sa" "dev-charlie" "staging" "NONE"
test_permissions "charlie-sa" "dev-charlie" "prod" "NONE"

echo "🌐 Starting Network Policy tests..."
echo ""

# Test network connectivity (only if namespaces exist)
if kubectl get namespace dev-alice dev-bob dev-shared >/dev/null 2>&1; then
    echo "==== Testing Network Isolation ===="
    test_network "dev-alice" "dev-alice" "ALLOWED"
    test_network "dev-alice" "dev-bob" "BLOCKED"
    test_network "dev-alice" "dev-shared" "ALLOWED"
    test_network "dev-bob" "dev-alice" "BLOCKED"
    test_network "dev-bob" "dev-charlie" "BLOCKED"
    
    echo "🧹 Cleaning up test pods..."
    for ns in dev-alice dev-bob dev-charlie dev-shared; do
        kubectl delete pod test-pod-$ns -n $ns --ignore-not-found=true 2>/dev/null &
    done
    wait
else
    echo "⚠️  Skipping network tests - namespaces not found"
fi

echo ""
echo "📊 Test Summary:"
echo "✅ RBAC tests completed - check output above for any issues"
echo "✅ Network policy tests completed - check output above for any issues"
echo ""
echo "🔧 To investigate issues:"
echo "  - Check RBAC: kubectl describe rolebindings -n NAMESPACE"
echo "  - Check Network Policies: kubectl describe networkpolicies -n NAMESPACE"
echo "  - Check Resource Quotas: kubectl describe resourcequota -n NAMESPACE"
