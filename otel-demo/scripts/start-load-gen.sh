#!/usr/bin/env bash
set -euo pipefail
REPLICAS="${REPLICAS:-3}"
echo "Scaling load-generator to ${REPLICAS} replicas"
kubectl scale deployment/load-generator -n ecommerce --replicas="${REPLICAS}"
echo "Watching error rate (Ctrl-C to stop)..."
CH_POD=$(kubectl get pod -n clickhouse -l app=clickhouse -o jsonpath='{.items[0].metadata.name}')
while :; do
  RATE=$(kubectl exec -n clickhouse "$CH_POD" -- clickhouse-client --query "
    SELECT round(countIf(SeverityText IN ('ERROR','Error')) / count(), 3)
    FROM otel_logs
    WHERE ServiceName = 'ecommerce-api'
      AND Timestamp > now() - INTERVAL 1 MINUTE" 2>/dev/null || echo "?")
  echo "$(date +%H:%M:%S) error rate (last 1m): ${RATE}"
  sleep 10
done
