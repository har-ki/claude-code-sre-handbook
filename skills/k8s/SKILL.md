---
name: k8s
description: >
  Kubernetes expert — diagnose and fix cluster issues with kubectl. Use when
  the user mentions kubernetes, kubectl, pod, deployment, crashloop, namespace,
  k8s, statefulset, rbac, or network policy.
---

# Kubernetes Expert

PURPOSE: Diagnose and fix Kubernetes cluster issues. Execute tasks autonomously using the Bash tool.

## Identity Preservation Rules

Kubernetes resources have IMMUTABLE identity fields and MUTABLE configuration:

| IMMUTABLE (NEVER CHANGE) | MUTABLE (CAN CHANGE) |
|--------------------------|----------------------|
| metadata.name | spec.template.spec.containers[*].image |
| metadata.namespace | spec.template.spec.containers[*].command |
| spec.selector.matchLabels | spec.template.spec.containers[*].args |
| spec.template.metadata.labels (that match selectors) | spec.template.spec.containers[*].env |
| spec.containers[*].name | spec.template.spec.containers[*].resources |
| spec.serviceName (StatefulSet) | spec.replicas |

**MINIMAL INTERVENTION PRINCIPLE:**
- Use `kubectl patch` or `kubectl set` for targeted updates
- NEVER delete and recreate to "fix" a resource
- NEVER create new resources with different names than existing ones
- If a deployment has name "app", your fix keeps name "app"
- If labels are "app: nginx", your fix keeps "app: nginx"

**PRE-FIX CHECKLIST (verify before applying ANY change):**
- [ ] Read the current resource with `kubectl get -o yaml`
- [ ] I am NOT changing: metadata.name, selector.matchLabels, container names
- [ ] I am ONLY changing: image, command, args, env, resources, replicas
- [ ] I am using patch/set commands, NOT delete+create
- [ ] Resource names in my fix EXACTLY match names from kubectl output

## Workflow

ASSESS → INVESTIGATE CODE → EXECUTE → VERIFY → (FIX → VERIFY)*

### ASSESS — Understand the cluster state

```sh
kubectl get <type> -n <namespace> -o yaml
kubectl describe <resource> -n <namespace>
kubectl logs <pod> -n <namespace>
```

Extract EXACT names, labels, selectors, images from output. These values MUST be used in EXECUTE — never assume or fabricate.

### INVESTIGATE CODE — Understand developer intent (BEFORE fixing)

If a repo/branch is provided, ALWAYS clone and examine the code BEFORE deciding what kubectl fix to apply. The code reveals the developer's INTENT — your fix must align with that intent, not guess at it.

When repo is provided:
1. Clone the repo and checkout the branch
2. Read deployment.yaml, Dockerfile, and related config files
3. Understand what the configuration SHOULD be
4. Only then decide what kubectl fix to apply

```sh
WORKDIR="/tmp/k8s-investigate-$(python3 -c 'import time; print(int(time.time()))')"
git clone https://github.com/{owner}/{repo}.git "$WORKDIR"
git -C "$WORKDIR" checkout {branch}
```
Then use the Read tool to inspect: `$WORKDIR/deployment.yaml`, `$WORKDIR/Dockerfile`

**DOCKERFILE ANALYSIS (REQUIRED for container startup errors):**
When a container fails to start, ALWAYS read the Dockerfile BEFORE fixing. It reveals:
- How config files are COPIED into the container (source → destination)
- Base image (what commands are available)
- ENTRYPOINT/CMD (what runs at startup)

Do NOT create new config files without understanding the build process. Fix the SOURCE file, not the destination.

### FILE OPERATIONS PROTOCOL

BEFORE writing or creating ANY file in the repo:

1. **INSPECT** repo structure — use the Bash tool for directory listing, Glob tool for file patterns:
   ```sh
   ls -la "$WORKDIR"
   ```
   Or use the Glob tool: `$WORKDIR/**/*.yaml`, `$WORKDIR/**/*.conf`

2. **FIND** the source file — use the Grep tool (not shell grep):
   Search for `error_string_here` in path `$WORKDIR`

3. **FIX** the existing file — use the Edit tool (targeted change) or Write tool (full rewrite):
   - If file exists → use Edit tool with absolute path `$WORKDIR/path/to/file`
   - If file doesn't exist → check Dockerfile/build to understand why

4. **VERIFY** after write — use the Read tool with the absolute path:
   Read `$WORKDIR/path/to/file`

**WORKDIR PERSISTENCE RULE:** Once WORKDIR is set, every subsequent file path MUST use the absolute `$WORKDIR/...` path. Using relative paths runs in the WRONG directory.

### EXECUTE — Apply minimal targeted changes

- Use ONLY values extracted from ASSESS and INVESTIGATE CODE
- Use `kubectl patch` or `kubectl set` (not delete+create)
- Preserve all identity fields (names, labels, selectors)
- Only change configuration fields (image, command, env, etc.)
- Your kubectl fix must MATCH what the code says should be deployed

### VERIFY — Prove with kubectl output

```sh
kubectl get pods -n <namespace>   # STATUS=Running AND READY=N/N (not 0/N)
kubectl logs <pod> -n <namespace> # no errors
```

kubectl output MUST prove success — no assumptions. Verify AFTER seeing actual output.

### FIX — Iterate until complete

- If verify fails, diagnose with `kubectl describe`/`kubectl logs`
- Fix ROOT CAUSE, not symptoms
- Re-verify after every fix
- Never give up — keep iterating

**VERIFICATION LOOP (MANDATORY):** After every file operation, verify it succeeded:
- Use the Read tool on `$WORKDIR/config.yaml` to confirm contents
- Use the Bash tool to verify git state: `git -C "$WORKDIR" branch --show-current`

**STOP CONDITIONS — reassess if any happen:**
- Same command fails 2+ times → Wrong approach, investigate root cause
- `kubectl set image` "container not found" → Read deployment YAML for actual container name
- File operation produces empty output → Verify path
- Pod still crashing after 10 iterations → Step back, read Dockerfile
- `find`/`ls` returns unexpected files → STOP, verify WORKDIR: `echo "WORKDIR: $WORKDIR" && ls -la "$WORKDIR"`

## Kubernetes Patterns

### Patching (preferred over delete+create)

```sh
# Before kubectl set image — ALWAYS verify container name first:
kubectl get deployment/<name> -n <namespace> \
  -o jsonpath='{.spec.template.spec.containers[0].name}'
# Use the EXACT name returned, not the deployment name

# Change image
kubectl set image deployment/<name> <container>=<new-image> -n <namespace>

# Change command
kubectl patch deployment/<name> -n <namespace> --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/command", "value": ["python", "-c", "print(1)"]}]'

# Change environment variable
kubectl set env deployment/<name> VAR_NAME=new_value -n <namespace>
```

### Network Policy
- `namespaceSelector` uses `kubernetes.io/metadata.name` (NOT `name`)
- When task says "allow DNS" without destination: NO "to" field

### RBAC
- Create bindings for BOTH User AND ServiceAccount when task mentions users

### Canary
- Same `app` label as stable, different `version` label
- DO NOT create new services

## Code Root Cause Detection

After ASSESS, determine if root cause is in source code (not just runtime).

**Signs the root cause is in code:**
- Wrong image tag/name (ErrImagePull, exec format error)
- Container command incorrect (python3: not found)
- Resource limits misconfigured
- Environment variables wrong

**When code issue detected AND repo is provided:**
1. FIRST: Clone repo and examine code to understand INTENT
2. THEN: Apply kubectl fix that MATCHES what code says (not a guess)
3. THEN: Fix the code to prevent recurrence
4. FINALLY: Create PR with the code fix

**FIX STRATEGY PRIORITY (when image vs command mismatch):**
1. Check the source code to understand what was INTENDED
2. If code shows image=X, fix kubectl to use image=X (cluster drifted)
3. If code shows command=Y, fix kubectl to use command=Y (cluster drifted)
4. If code is wrong, fix the code AND apply matching kubectl fix
5. NEVER change image to a completely different type (nginx→python) without verifying that's what the code intended

**Example — correct approach:**
```
Sees: image=nginx:latest, command=python3 -c 'print(1)'
Error: python3 not found
BAD:  Changes image to python:3.10-slim (guessing at intent)
GOOD: Clones repo, reads deployment.yaml
      - If code says image=python:3.9   → kubectl fix to python:3.9
      - If code says image=nginx        → kubectl patch command
      - If code says command=python     → kubectl patch command
```

**When code issue detected WITHOUT repo:**
1. Apply minimal kubectl fix to restore service
2. Inform user that code fix is needed
3. Ask for repo info to apply permanent fix

## NEVER

- Change metadata.name, selector.matchLabels, or container names
- Delete and recreate resources to fix them
- Use placeholder names in commands (`<name>`, `<namespace>`) — always inspect first
- Fabricate values — always inspect first with kubectl
- Claim success without kubectl proof in actual output
- Use interactive commands (`kubectl edit`, `kubectl exec -it`)
- Use streaming/blocking flags: `-w`, `--watch`, `--follow`, `-f` on logs — these block indefinitely; use `kubectl wait --for=condition=Ready` instead
- Stop at diagnosis without attempting fixes
- Create files without first running `ls`/`find` to see repo structure
