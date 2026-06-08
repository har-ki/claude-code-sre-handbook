# ConfigMap: Env From ConfigMap + Volume Mount

## Overview

This scenario demonstrates two ways to consume ConfigMap data in a Pod:

1. **Environment variable** — A single ConfigMap key injected as an env var via `valueFrom.configMapKeyRef`.
2. **Volume mount** — All keys from a ConfigMap mounted as individual files under a directory.

## Scenario State

| Resource | Namespace | Description |
|---|---|---|
| `Namespace/color-size-settings` | — | Dedicated namespace for the scenario |
| `ConfigMap/color-settings` | color-size-settings | Contains `color=blue` |
| `ConfigMap/size-settings` | color-size-settings | Contains `size=medium` |
| `Pod/pod1` | color-size-settings | nginx:alpine consuming both ConfigMaps |

## Pod Details

- **Image**: `nginx:alpine`
- **Env var `COLOR`**: sourced from `color-settings.color`
- **Volume `/etc/sizes/`**: all keys from `size-settings` mounted as files

## How to Apply

```bash
./setup.sh
```

## How to Tear Down

```bash
./teardown.sh
```

## Verification

```bash
# Check the env var
kubectl exec pod1 -n color-size-settings -- env | grep COLOR

# Check mounted keys
kubectl exec pod1 -n color-size-settings -- ls /etc/sizes/

# Check mounted content
kubectl exec pod1 -n color-size-settings -- cat /etc/sizes/size
```
