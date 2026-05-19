# Multi-Tenant Kubernetes Development Environment

This directory contains the configuration for setting up a secure, multi-tenant Kubernetes development environment for 3 developers (alice, bob, and charlie).

## Overview

The setup creates:
- **6 namespaces**: Individual developer namespaces, shared resources, staging, and production
- **RBAC configuration**: Service accounts, roles, and role bindings for proper access control
- **Resource quotas**: CPU, memory, and object limits for each namespace
- **Network policies**: Tenant isolation and controlled communication paths
- **Security**: Default deny policies with selective allow rules

## Architecture

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   dev-alice     │  │   dev-bob       │  │  dev-charlie    │
│                 │  │                 │  │                 │
│ ✅ Full access  │  │ ✅ Full access  │  │ ✅ Full access  │
│ 🔒 Isolated     │  │ 🔒 Isolated     │  │ 🔒 Isolated     │
│ 📊 2CPU/4Gi     │  │ 📊 2CPU/4Gi     │  │ 📊 2CPU/4Gi     │
└─────────────────┘  └─────────────────┘  └─────────────────┘
         │                    │                    │
         └────────────────────┼────────────────────┘
                              │
                              ▼
                   ┌─────────────────┐
                   │   dev-shared    │
                   │                 │
                   │ 👀 Read-only    │
                   │ 🤝 Shared       │
                   │ 📊 4CPU/8Gi     │
                   └─────────────────┘

┌─────────────────┐  ┌─────────────────┐
│    staging      │  │      prod       │
│                 │  │                 │
│ 🔐 Admin only   │  │ 🔐 Admin only   │
│ 🚫 Isolated    │  │ 🚫 Isolated    │
│ 📊 8CPU/16Gi    │  │ 📊 8CPU/16Gi    │
└─────────────────┘  └─────────────────┘
```

## Namespaces

| Namespace | Purpose | Resource Limits | Access |
|-----------|---------|-----------------|--------|
| `dev-alice` | Alice's development workspace | 2 CPU, 4Gi RAM, 10 pods | alice (full) |
| `dev-bob` | Bob's development workspace | 2 CPU, 4Gi RAM, 10 pods | bob (full) |
| `dev-charlie` | Charlie's development workspace | 2 CPU, 4Gi RAM, 10 pods | charlie (full) |
| `dev-shared` | Shared development resources | 4 CPU, 8Gi RAM, 20 pods | all devs (read-only) |
| `staging` | Staging environment | 8 CPU, 16Gi RAM, 50 pods | admins only |
| `prod` | Production environment | 8 CPU, 16Gi RAM, 50 pods | admins only |

## Security Model

### RBAC (Role-Based Access Control)
- **Service Accounts**: Each developer has a dedicated service account in their namespace
- **Roles**: Full access within own namespace, read-only access to shared namespace
- **No Cross-Tenant Access**: Developers cannot access other developers' namespaces

### Network Policies
- **Default Deny**: All traffic blocked by default
- **Selective Allow**: Only specific communication patterns are permitted:
  - ✅ Intra-namespace communication
  - ✅ Access to DNS (kube-system)
  - ✅ Developer namespaces → dev-shared (read-only)
  - 🚫 Cross-developer namespace communication
  - 🚫 Access to staging/prod from dev namespaces

### Resource Quotas
- **CPU & Memory**: Hard limits prevent resource hogging
- **Object Limits**: Pods, services, secrets, configmaps are limited
- **Storage**: PVC limits to control disk usage

## Files

- **`multi-tenant-dev-environment.yaml`**: Complete Kubernetes configuration
- **`setup.sh`**: Automated setup script
- **`teardown.sh`**: Cleanup script (run to remove the environment)
- **`test-access.sh`**: Script to test RBAC permissions

## Setup Instructions

### Prerequisites
- Kubernetes cluster (v1.20+)
- `kubectl` configured and connected to the cluster
- Cluster admin permissions

### Installation

1. **Clone and navigate to the directory**:
   ```bash
   cd multi-tenant-setup/
   ```

2. **Run the setup script**:
   ```bash
   ./setup.sh
   ```

3. **Verify the installation**:
   ```bash
   # Check namespaces
   kubectl get namespaces --show-labels

   # Check resource quotas
   kubectl get resourcequota --all-namespaces

   # Check network policies
   kubectl get networkpolicies --all-namespaces
   ```

### Manual Installation
If you prefer to apply the configuration manually:

```bash
kubectl apply -f multi-tenant-dev-environment.yaml
```

## Usage Examples

### Testing RBAC Permissions
```bash
# Test alice's permissions in her own namespace
kubectl auth can-i --list --as=system:serviceaccount:dev-alice:alice-sa -n dev-alice

# Test alice's permissions in bob's namespace (should be empty)
kubectl auth can-i --list --as=system:serviceaccount:dev-alice:alice-sa -n dev-bob

# Test alice's permissions in shared namespace
kubectl auth can-i --list --as=system:serviceaccount:dev-alice:alice-sa -n dev-shared
```

### Creating Developer Kubeconfig Files
```bash
# Create kubeconfig for alice
kubectl config set-context dev-alice \
  --cluster=$(kubectl config current-context) \
  --user=alice-sa \
  --namespace=dev-alice

# Get alice's service account token
TOKEN=$(kubectl get secret $(kubectl get sa alice-sa -n dev-alice -o jsonpath='{.secrets[0].name}') -n dev-alice -o jsonpath='{.data.token}' | base64 -d)

kubectl config set-credentials alice-sa --token=$TOKEN
```

### Deploying Sample Applications
```bash
# Deploy a test pod in alice's namespace
kubectl run test-pod --image=nginx -n dev-alice

# Check resource quota usage
kubectl describe resourcequota dev-resource-quota -n dev-alice

# Test network connectivity (should work within namespace)
kubectl exec -n dev-alice test-pod -- ping service-in-same-namespace
```

## Testing Network Isolation

### Test Communication Patterns
```bash
# Deploy test pods
kubectl run alice-pod --image=nginx -n dev-alice
kubectl run bob-pod --image=nginx -n dev-bob
kubectl run shared-pod --image=nginx -n dev-shared

# Test allowed: alice-pod → shared-pod (should work)
kubectl exec -n dev-alice alice-pod -- curl shared-pod.dev-shared.svc.cluster.local

# Test blocked: alice-pod → bob-pod (should fail)
kubectl exec -n dev-alice alice-pod -- curl bob-pod.dev-bob.svc.cluster.local
```

## Troubleshooting

### Common Issues

1. **Network Policy Not Working**
   - Check if your CNI supports NetworkPolicies (Calico, Cilium, etc.)
   - Verify kube-system namespace has the correct label

2. **RBAC Permission Denied**
   - Verify service account exists
   - Check role bindings
   - Ensure you're using the correct context

3. **Resource Quota Exceeded**
   - Check current usage: `kubectl describe resourcequota -n NAMESPACE`
   - Adjust quotas if needed

4. **DNS Resolution Issues**
   - Check DNS network policy allows kube-system access
   - Verify CoreDNS is running

### Debugging Commands
```bash
# Check all resources in a namespace
kubectl get all -n dev-alice

# Describe network policies
kubectl describe networkpolicy -n dev-alice

# Check service account tokens
kubectl get serviceaccounts -n dev-alice -o yaml

# View resource quota usage
kubectl top nodes
kubectl top pods --all-namespaces
```

## Cleanup

To remove the entire multi-tenant setup:

```bash
./teardown.sh
```

Or manually:
```bash
kubectl delete -f multi-tenant-dev-environment.yaml
```

## Security Considerations

1. **Service Account Tokens**: In production, consider using:
   - Short-lived tokens
   - External identity providers (OIDC)
   - Workload Identity (GKE) or IAM Roles for Service Accounts (EKS)

2. **Network Policies**: 
   - Regularly audit and update policies
   - Consider using tools like Falco for runtime security monitoring

3. **Resource Monitoring**:
   - Set up monitoring for resource usage
   - Implement alerting for quota violations

4. **Pod Security**:
   - Consider implementing Pod Security Standards
   - Use admission controllers like OPA Gatekeeper

## Extension Points

This setup can be extended with:
- **Ingress Controllers**: For external access
- **Service Mesh**: For advanced traffic management (Istio, Linkerd)
- **GitOps**: For declarative deployments (ArgoCD, Flux)
- **Monitoring**: Prometheus, Grafana for observability
- **Policy Engines**: OPA Gatekeeper for advanced policies

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Kubernetes documentation for RBAC and NetworkPolicies
3. Test with minimal examples to isolate issues
