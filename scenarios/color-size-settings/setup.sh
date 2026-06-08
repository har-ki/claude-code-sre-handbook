#!/usr/bin/env bash
set -euo pipefail

NS="color-size-settings"

echo "=== Creating namespace '$NS' ==="
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Applying ConfigMaps ==="
kubectl apply -f scenarios/color-size-settings/manifests/configmaps.yaml

echo "=== Applying Pod ==="
kubectl apply -f scenarios/color-size-settings/manifests/pod.yaml

echo "=== Waiting for pod to be ready ==="
kubectl wait -n "$NS" pod/pod1 --for=condition=Ready --timeout=60s

echo "=== Verifying ENV var COLOR from color-settings ConfigMap ==="
kubectl exec -n "$NS" pod/pod1 -- printenv COLOR

echo "=== Verifying size-settings ConfigMap mounted at /etc/sizes/ ==="
kubectl exec -n "$NS" pod/pod1 -- ls /etc/sizes/
kubectl exec -n "$NS" pod/pod1 -- cat /etc/sizes/size

echo "=== Done ==="
