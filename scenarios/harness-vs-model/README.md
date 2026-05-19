# Harness vs Model Experiment

Experiment for [Post 1 — The Harness Problem](../../docs/handbook/01-harness-problem.md).
Three AI SRE tools investigate the same crash-looping pod on the same cluster.
Same model class, different harnesses, different outcomes.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) (v0.20+)
- Docker
- kubectl
- curl, jq
- [HolmesGPT](https://github.com/robusta-dev/holmesgpt) (`pip install holmesgpt`)
- [Claude Code](https://claude.ai/claude-code)
- `ANTHROPIC_API_KEY` environment variable

---

## Step 1 — Set up the scenario

```bash
cd scenarios/harness-vs-model
./setup.sh
```

The script creates a kind cluster (`harness-experiment`) with Calico CNI,
deploys services across namespaces, and applies a NetworkPolicy. It waits
until the checkout pod enters `CrashLoopBackOff`.

Takes ~3 minutes (mostly waiting for Calico to initialize).

Verify the scenario is ready:

```bash
kubectl get pods -n ecommerce
kubectl logs -n ecommerce -l app=checkout --tail=10
```

---

## Step 2 — Run the k8sgpt-style harness

This replicates what k8sgpt does: extract the pod error string, wrap it in
k8sgpt's exact prompt template (from `pkg/ai/prompts.go`), and send it to
the Anthropic Messages API. The model receives **only** the error string —
no kubectl access, no cluster state, no follow-up queries.

```bash
export ANTHROPIC_API_KEY="sk-ant-..."

# Run with Sonnet (default)
./k8sgpt-harness/run.sh

# Optionally run with Opus for comparison
./k8sgpt-harness/run.sh --model claude-opus-4-20250514
```

The response is saved to `transcripts/`.

---

## Step 3 — Run HolmesGPT

```bash
holmes ask --model "anthropic/claude-sonnet-4-20250514" \
  "What is wrong with ecommerce namespace?"
```

HolmesGPT uses its built-in toolset (kubectl read-only, Prometheus if
configured). Note where the investigation stops.

---

## Step 4 — Run Claude Code

Start Claude Code from the `claude-code-harness/` directory so it picks up
the workspace `CLAUDE.md`:

```bash
cd claude-code-harness
claude
```

When Claude Code starts, paste this prompt:

```text
A pod in the ecommerce namespace is crash-looping. Investigate the root cause.
Do not stop at the first plausible explanation — verify your hypothesis by
cross-referencing cluster state.
```

Save the session transcript to `transcripts/`.

---

## Step 5 — Tear down

```bash
./teardown.sh
```

Deletes the kind cluster. Idempotent.

