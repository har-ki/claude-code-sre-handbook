# Multi-Tenant Kubernetes Development Environment

This scenario demonstrates a secure, multi-tenant Kubernetes development cluster with strict namespace isolation, RBAC-based access control, resource quotas, and network policies.

## Architecture

```
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│  dev-alice    │   │  dev-bob      │   │ dev-charlie   │
│              │   │              │   │              │
│ Full access  │   │ Full access  │   │ Full access  │
│ 2 CPU / 4Gi  │   │ 2 CPU / 4Gi  │   │ 2 CPU / 4Gi  │
│ 10 pods, 5 svc│  │ 10 pods, 5 svc│  │ 10 pods, 5 svc│
│              │   │              │   │              │
│ └───┐        │   │ └───┐        │   │ └───┐        │
│     ▼        │   │     ▼        │   │     ▼        │
│  dev-shared  ◄───┘  dev-shared  ◄───┘  dev-shared  │
│  Read-only     │   │ Read-only     │   │ Read-only     │
│  4 CPU / 8Gi   │   │ 4 CPU / 8Gi   │   │ 4 CPU / 8Gi   │
└──────────────┘   └──────────────┘   └──────────────┘

┌──────────────┐   ┌──────────────┐
│  staging      │   │  prod         │
│              │   │              │
│ Admin only   │   │ Admin only   │
│ 8 CPU / 16Gi │   │ 8 CPU / 16Gi │
│ 50 pods      │   │ 50 pods      │
│ Isolated     │   │ Isolated     │
└──────────────┘   └──────────────┘
```

## Namespaces

| Namespace | Purpose | CPU | Memory | Pods | Services | Access |
|-----------|---------|-----|--------|------|----------|--------|
| `dev-alice` | Alice's dev workspace | 2 | 4Gi | 10 | 5 | alice (full) |
| `dev-bob` | Bob's dev workspace | 2 | 4Gi | 10 | 5 | bob (full) |
| `dev-charlie` | Charlie's dev workspace | 2 | 4Gi | 10 | 5 | charlie (full) |
| `dev-shared` | Shared dev resources | 4 | 8Gi | 20 | 10 | all devs (read-only) |
| `staging` | Staging environment | 8 | 16Gi | 50 | 20 | admins only |
| `prod` | Production environment | 8 | 16Gi | 50 | 20 | admins only |

## Security Model

### RBAC

- Each developer gets a **dedicated service account** (`alice-sa`, `bob-sa`, `charlie-sa`) in their namespace
- **Full admin access** within their own namespace (RoleBinding → Developer Role)
- **Read-only access** to `dev-shared` for viewing shared resources
- **Admin access** to `staging` and `prod` for **cluster admins only** (via `system:masters` group)
- **No access** to `staging` and `prod` for developers (alice, bob, charlie)
- Zero access between developer namespaces (alice cannot reach bob)

### Network Policies (Zero-Trust Model)

| From | To | Allowed? | How |
|------|------|----------|-----|
| dev-alice | dev-bob | No | Default deny blocks |
| dev-alice | dev-charlie | No | Default deny blocks |
| dev-bob | dev-charlie | No | Default deny blocks |
| dev-alice | dev-shared | Yes | Explicit egress policy |
| dev-shared | dev-alice | Yes | Explicit egress policy (response) |
| dev-* | staging | No | Fully isolated (default deny) |
| dev-* | prod | No | Fully isolated (default deny) |
| staging | prod | No | Fully isolated (default deny) |
| staging | dev-* | No | Fully isolated (default deny) |
| prod | dev-* | No | Fully isolated (default deny) |
| all | kube-system | Yes | DNS access |

All namespaces implement **default deny ingress + egress** as their baseline. Traffic is only allowed through explicit allow policies.

### Resource Quotas

Each namespace has hard limits on CPU, memory, and object counts to prevent resource exhaustion and ensure fair distribution across tenants.

## Quick Start

```bash
# Setup the environment
./setup.sh

# Tear down the environment
./teardown.sh
```

### Manual Application

```bash
# Apply all manifests
kubectl apply -f manifests/

# Or apply individual files
kubectl apply -f manifests/01-namespaces.yaml
kubectl apply -f manifests/02-service-accounts.yaml
kubectl apply -f manifests/03-rbac.yaml
kubectl apply -f manifests/04-resource-quotas.yaml
kubectl apply -f manifests/05-network-policies.yaml
```

## Testing Access

```bash
# Test Alice's full access in her namespace
kubectl auth can-i --list \
  --as=system:serviceaccount:dev-alice:alice-sa \
  -n dev-alice

# Test Alice CANNOT access Bob's namespace
kubectl auth can-i --list \
  --as=system:serviceaccount:dev-alice:alice-sa \
  -n dev-bob
# Expected: empty output (no permissions)

# Test Alice's read-only access to dev-shared
kubectl auth can-i --list \
  --as=system:serviceaccount:dev-alice:alice-sa \
  -n dev-shared

# Test network isolation
kubectl run test-alice --image=busybox -n dev-alice --restart=Never \
  --command -- sh -c "wget --timeout=5 dev-bob:80 2>&1 || echo 'BLOCKED - correct!'"
```

## File Structure

```
scenarios/multi-tenant-dev/
├── manifests/
│   ├── 01-namespaces.yaml          # All 6 namespaces
│   ├── 02-service-accounts.yaml    # Service accounts for each dev
│   ├── 03-rbac.yaml                # Roles, ClusterRoles, bindings
│   ├── 04-resource-quotas.yaml     # CPU/memory/pod quotas per namespace
│   └── 05-network-policies.yaml    # Default deny + explicit allow policies
├── setup.sh                        # Idempotent setup script
├── teardown.sh                     # Cleanup script
└── README.md                       # This file
```

## Design Decisions

1. **Default deny on all namespaces** — Zero-trust baseline ensures no accidental
   cross-namespace communication, even if an allow policy is misconfigured.

2. **Intra-namespace allow via `podSelector: {}`** — Simplified to allow all pods
   within the same namespace to communicate without needing pod-specific selectors.

3. **DNS via explicit kube-system selector** — Rather than allowing egress to any
   namespace on port 53, we restrict DNS to kube-system only, following least privilege.

4. **staging/prod fully isolated** — No egress to dev namespaces and no ingress from
   dev namespaces. Only intra-namespace + DNS + kube-system allowed.

5. **Read-only dev-shared ingress** — Developers can send traffic TO dev-shared via
   egress policy, and dev-shared explicitly allows ingress from dev namespaces.

6. **Separate namespace-level roles vs cluster roles** — Roles are namespace-scoped
   for least privilege. ClusterRole used only for staging/prod admin access where
   cross-namespace permissions are needed.
