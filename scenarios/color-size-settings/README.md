# ConfigMap as Environment Variable and Volume Mount

## Problem

Create a namespace with two ConfigMaps and a pod that consumes them in different ways:
one as an environment variable via `configMapKeyRef`, and another as mounted files on the filesystem.

## Expected Outcome

- Namespace `color-size-settings` is created.
- ConfigMap `color-settings` contains `color: blue`.
- ConfigMap `size-settings` contains `size: medium`.
- Pod `pod1` (nginx:alpine) reads `COLOR` from `color-settings` ConfigMap and mounts `size-settings` ConfigMap under `/etc/sizes/`.

## How to Verify

```sh
# Check CONFIGMAP env var
kubectl exec -n color-size-settings pod/pod1 -- printenv COLOR
# Expected: blue

# Check CONFIGMAP volume mount
kubectl exec -n color-size-settings pod/pod1 -- cat /etc/sizes/size
# Expected: medium
```
