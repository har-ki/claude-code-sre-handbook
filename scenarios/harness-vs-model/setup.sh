#!/usr/bin/env bash
# Setup script for the harness-vs-model experiment.
# Creates a kind cluster with Calico CNI (for NetworkPolicy enforcement),
# deploys a broken scenario, and waits for CrashLoopBackOff.
#
# Idempotent — safe to run multiple times.

set -euo pipefail

CLUSTER_NAME="harness-experiment"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALICO_VERSION="v3.28.0"

echo "=== Harness vs Model Experiment Setup ==="

# ── 1. Kind cluster ──────────────────────────────────────────────────────────

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[ok] kind cluster '${CLUSTER_NAME}' already exists"
else
  echo "[..] creating kind cluster '${CLUSTER_NAME}' (Calico CNI)..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
- role: control-plane
EOF
  echo "[ok] cluster created"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ── 2. Install Calico (required for NetworkPolicy enforcement) ───────────────

if kubectl get daemonset -n kube-system calico-node &>/dev/null; then
  echo "[ok] calico already installed"
else
  echo "[..] installing calico ${CALICO_VERSION}..."
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    --server-side --force-conflicts >/dev/null
  echo "[ok] calico manifests applied"
fi

echo "[..] waiting for calico to be ready (up to 120s)..."
kubectl rollout status daemonset/calico-node -n kube-system --timeout=120s
kubectl rollout status deployment/calico-kube-controllers -n kube-system --timeout=60s
echo "[ok] calico ready"

# ── 3. Wait for node ready ──────────────────────────────────────────────────

echo "[..] waiting for node to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null
echo "[ok] node ready"

# ── 4. Apply broken manifests ────────────────────────────────────────────────

echo "[..] applying scenario manifests..."

kubectl apply -f "${SCRIPT_DIR}/manifests/namespace.yaml"

kubectl apply -f "${SCRIPT_DIR}/manifests/database.yaml"

echo "[..] waiting for postgres to be ready (up to 90s)..."
kubectl rollout status deployment/postgres -n database --timeout=90s
echo "[ok] postgres ready"

# Apply the NetworkPolicy first, then deploy checkout.
# This ensures the pod is blocked from its first attempt.
# In production the sequence would be reversed (app was working, then policy
# was applied), but for a reproducible experiment we need the failure on
# every run.
kubectl apply -f "${SCRIPT_DIR}/manifests/networkpolicy.yaml"

kubectl apply -f "${SCRIPT_DIR}/manifests/checkout.yaml"

echo "[ok] all manifests applied"

# ── 5. Wait for CrashLoopBackOff ────────────────────────────────────────────

echo "[..] waiting for checkout pod to enter CrashLoopBackOff (up to 90s)..."

for i in $(seq 1 30); do
  STATUS=$(kubectl get pod -n ecommerce -l app=checkout \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  if [ "${STATUS}" = "CrashLoopBackOff" ]; then
    break
  fi
  sleep 3
done

echo ""
echo "=== Scenario Status ==="
echo ""
kubectl get pods -n ecommerce -l app=checkout
echo ""
echo "--- Last log output ---"
kubectl logs -n ecommerce -l app=checkout --tail=5 2>/dev/null || echo "(no logs yet)"
echo ""
echo "--- Pod status ---"
kubectl get pod -n ecommerce -l app=checkout \
  -o jsonpath='reason: {.items[0].status.containerStatuses[0].state.waiting.reason}{"\n"}' 2>/dev/null || true
echo ""

if [ "${STATUS}" = "CrashLoopBackOff" ]; then
  echo "[ok] scenario ready — checkout pod is in CrashLoopBackOff"
else
  echo "[!!] checkout pod is not yet in CrashLoopBackOff (status: ${STATUS})"
  echo "     wait a moment and check: kubectl get pods -n ecommerce"
fi

echo ""
echo "Next steps:"
echo "  1. Run the k8sgpt-style harness:  ./k8sgpt-harness/run.sh"
echo "  2. Run Claude Code from:          cd claude-code-harness && claude"
echo "  3. Tear down:                     ./teardown.sh"
