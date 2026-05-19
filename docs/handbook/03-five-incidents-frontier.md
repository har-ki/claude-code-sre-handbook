# 03 — Claude Code on k8s-ai-bench
*What happens when you measure?*

*Claude Code solved 21 to 23 out of 24 standard Kubernetes problems across three test setups. Adding custom skills can easily fix known weaknesses, while a more powerful model helps with new problems you haven't seen before. Try the open benchmark on your own system before relying on these results.*

[Post 2](02-investigation-to-pr.md) timed a single incident — investigation to PR in under six minutes. One scenario is a demo. Twenty-four scenarios are a benchmark. This post runs the same Skill against k8s-ai-bench's canonical Kubernetes failure suite and measures what holds up.

## Setup

Runner: [k8s-ai-bench](https://github.com/gke-labs/k8s-ai-bench) at commit `ac9ac9c`. Harness: Claude Code v2.1.84. Hardware: Apple M3 Pro, 36 GB.

```bash
claude -p \
  --dangerously-skip-permissions \
  --max-budget-usd 5 \
  --allowedTools "Bash" \
  --append-system-prompt "$(cat skills/k8s/SKILL.md)" \
  < <(echo "$PROMPT")
```

`--allowedTools "Bash"` restricts the agent to shell commands only — no file editing or search. The benchmark assesses kubectl-level cluster operations; broader tool access would increase the attack surface without aligning with the task scope.

`--append-system-prompt` is omitted in the No-Skill condition.

Each task runs in a fresh kind cluster — no shared state. A task passes when `verify.sh` exits 0. Best-of-3 retries per task. The full runner script is at [`benchmark/bin/run-k8s-ai-bench.sh`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/benchmark/bin/run-k8s-ai-bench.sh).

Three conditions:

- Sonnet + No Skill
- Sonnet + Skill
- Opus + No Skill

## Results

| Model | Skill | Pass rate | Notable failures |
|---|---|---|---|
| Sonnet 4.6 | Yes | 23/24 (96%) | setup-dev-cluster |
| Sonnet 4.6 | No | 21/24 (88%) | setup-dev-cluster, resize-pvc, create-canary-deployment |
| Opus 4.6 | No | 23/24 (96%) | resize-pvc |

*All three conditions evaluated against the same 24 canonical scenarios (gatekeeper sub-tasks excluded).*

Sonnet + Skill and Opus without the Skill both reach 23/24 — matching pass rates through different mechanisms. Opus's only failure is resize-pvc, where the kind's local-path provisioner doesn't support volume expansion. Sonnet + Skill's only failure is setup-dev-cluster, a multi-tenant RBAC problem that requires reasoning the Skill can't provide. Without the Skill, Sonnet drops to 21/24, and it picks up resize-pvc and create-canary-deployment failures. The Skill's value shows on specific tasks: resize-pvc passes only with the Skill's "patch don't delete" rule, and create-network-policy passes on the first attempt with the Skill's `kubernetes.io/metadata.name` rule. Aggregate scores hide these per-task effects.

## How Skills compensate

The task: write a NetworkPolicy that allows pods in ns1 to reach pods in ns2. The verifier compares the policy spec against a canonical configuration.

| Condition | Result | Policy produced |
|---|---|---|
| Sonnet + No Skill | fail | `namespaceSelector: name: ns2` + manual workaround: `kubectl label namespace ns2 name=ns2` |
| Opus + No Skill | pass (33s) | `namespaceSelector: kubernetes.io/metadata.name: ns2` |
| Sonnet + Skill | pass | `namespaceSelector: kubernetes.io/metadata.name: ns2` |

Sonnet without the Skill recognized the cluster didn't match its spec and patched the cluster — when it should have patched the spec. Every Kubernetes namespace gets `kubernetes.io/metadata.name` automatically. A `namespaceSelector` keyed on `name` works only by accident. Opus has the convention internalized.

The Skill rule that closes the gap for Sonnet is six words:

> namespaceSelector uses kubernetes.io/metadata.name (NOT name)

## Where it fails — and where it cheats

| Failure | Conditions | What broke |
|---|---|---|
| setup-dev-cluster | Sonnet ± Skill | Over-permissive RBAC; alice can read bob's namespace |
| resize-pvc | Sonnet No-Skill, Opus No-Skill | delete+recreate (Sonnet) or in-place patch hit kind provisioner limit (Opus) |
| fix-crashloop | Sonnet + Skill | Image swapped nginx → python + `sleep infinity` to keep the container alive |

### setup-dev-cluster — a reasoning failure

Sonnet is ambiguous about scope; it defaults to more permissions rather than fewer. The Skill includes RBAC guidance and doesn't override the pattern.

Opus passes in 2m 9s — after creating scoped RoleBindings, it verifies isolation, finds a pre-existing ClusterRoleBinding granting cluster-wide read access, and removes it. Sonnet never thought to check. Reasoning failures need a stronger model, not a rule.

### resize-pvc — environment-dependent

The Skill's "patch don't delete" rule moved Sonnet from delete-and-recreate to in-place patch, and the in-place patch passed.

Opus's first attempt also chose delete-and-recreate; its retry used the correct in-place patch, but it still failed because kind's `rancher.io/local-path` provisioner doesn't support PV expansion. So Sonnet + Skill's pass happened in an environment where Opus's correct fix couldn't. The Skill nudges toward the right approach; the environment determines whether it succeeds.

### fix-crashloop — a verifier-gaming pass

The broken state is a Deployment that runs `python3 -c 'print(\'Starting\')'` in an nginx image. The correct fix: remove the Python command, let nginx run. Sonnet + No Skill and Opus + No Skill both do this. Sonnet + Skill swaps the image to Python and adds `sleep infinity` to keep the container alive. The verifier passes — it checks readiness, not image identity. In production, a working web server replaced by a Python script that prints once and sleeps forever is a regression. The Skill's identity-preservation rule was present and violated. A rule in context is not a rule followed.

## What this means for your team

Claude Code solved nearly all standard Kubernetes incidents—21–23 out of 24—proving it works beyond theory.

**Start with your most frequent issues:** crashed pods, image pull errors, broken probes, and selector mismatches. If these fill your incident queue, Claude Code can save your team time and stress. Pilot it where it matters most.

**Decide your investment:** add quick Skills for known problems or upgrade to a stronger model for new, complex cases. Most teams need both—Skills for routine issues, a stronger model for surprises.

**A test "pass" isn't production-ready.** Always review AI fixes—by a human, extra tests, or staging—before deploying.

**Finally, test on your own systems.** The benchmark is a baseline; your real-world incidents will show true value and highlight any gaps. Trust the results, but always verify in your environment.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
