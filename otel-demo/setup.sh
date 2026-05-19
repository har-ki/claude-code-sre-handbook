#!/usr/bin/env bash
#
# Stands up the demo: kind cluster, ClickHouse, OTel bridge,
# ecommerce app, and load generator.
# Idempotent. Requires: docker, kind, kubectl.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${KIND_CLUSTER:-claude-sre-demo}"

# ── Pre-flight ────────────────────────────────────────────────────
echo "==> Pre-flight checks"
for cmd in docker kind kubectl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not in PATH" >&2; exit 1; }
done

# ── Kind cluster ──────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "==> Kind cluster '${CLUSTER_NAME}' exists, skipping creation"
else
  echo "==> Creating kind cluster '${CLUSTER_NAME}'"
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── Pre-pull infra images ─────────────────────────────────────────
echo "==> Loading infrastructure images into kind"
for img in clickhouse/clickhouse-server:25.3-alpine otel/opentelemetry-collector-contrib:0.114.0; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
  kind load docker-image "$img" --name "${CLUSTER_NAME}" 2>/dev/null || true
done

# ── Build app image from local source ─────────────────────────────
echo "==> Building ecommerce-api"
docker build -t ecommerce-api:latest "${SCRIPT_DIR}/ecommerce/backend"
kind load docker-image ecommerce-api:latest --name "${CLUSTER_NAME}"

# ── Deploy ────────────────────────────────────────────────────────
echo "==> Namespaces"
kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"

echo "==> ClickHouse"
kubectl apply -f "${SCRIPT_DIR}/k8s/clickhouse.yaml"
kubectl wait --for=condition=ready pod -l app=clickhouse -n clickhouse --timeout=120s

echo "==> OTel bridge"
kubectl apply -f "${SCRIPT_DIR}/k8s/otel-bridge.yaml"
kubectl wait --for=condition=ready pod -l app=otel-clickhouse-bridge --timeout=120s

echo "==> Ecommerce app"
kubectl apply -f "${SCRIPT_DIR}/k8s/ecommerce.yaml"
kubectl wait --for=condition=ready pod -l app=ecommerce-api    -n ecommerce --timeout=120s
kubectl wait --for=condition=ready pod -l app=load-generator   -n ecommerce --timeout=120s

# ── Wait for telemetry ────────────────────────────────────────────
echo "==> Waiting for OTel data to land in ClickHouse"
CH_POD=$(kubectl get pod -n clickhouse -l app=clickhouse -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 30); do
  COUNT=$(kubectl exec -n clickhouse "$CH_POD" -- clickhouse-client \
    --query "SELECT count() FROM otel_logs WHERE ServiceName = 'ecommerce-api'" 2>/dev/null || echo "0")
  if [ "${COUNT:-0}" -gt 0 ] 2>/dev/null; then
    echo "    $COUNT log rows from ecommerce-api"
    break
  fi
  echo "    attempt $i/30 — no data yet, waiting 10s..."
  sleep 10
done

# ── Summary ───────────────────────────────────────────────────────
cat <<EOF

==> Demo ready
    Cluster:        kind-${CLUSTER_NAME}
    ClickHouse:     localhost:9000 (native), localhost:8123 (http)
    Query logs:     kubectl exec -n clickhouse ${CH_POD} -- clickhouse-client \\
                      --query "SELECT * FROM otel_logs LIMIT 5"
    Teardown:       ${SCRIPT_DIR}/teardown.sh
EOF
