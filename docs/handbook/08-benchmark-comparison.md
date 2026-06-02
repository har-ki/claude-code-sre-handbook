# 08 — The Same Problems, Locally: Air-Gapped Qwen3.6 on k8s-ai-bench

*Frontier vs. air-gapped on the same 24-scenario benchmark.*

A 35B coding model running fully air-gapped on a laptop achieved 21 out of 24 on the Kubernetes benchmark—just two short of Frontier Sonnet, both using the same Skill. None of the misses was a reasoning failure. Going air-gapped doesn't cost you capability; it costs you speed and hardware. That's the core trade-off, clearly illustrated by the three failures.

Post 3 ran k8s-ai-bench on frontier models with the SRE Skill; Sonnet 4.6 reached 23 out of 24. This post repeats all 24 scenarios using the same Skill and harness, but now Claude Code runs qwen3.6:35b-a3b-coding-nvfp4 locally on an M3 Pro laptop with Ollama.

## Setup

Same runner, harness, and hardware as Post 3—the only change is model and endpoint:

```bash
export ANTHROPIC_BASE_URL=http://localhost:11434
claude -p \
  --dangerously-skip-permissions \
  --allowedTools "Bash" \
  --model qwen3.6:35b-a3b-coding-nvfp4 \
  --append-system-prompt "$(cat skills/sre/SKILL.md)" \
  < <(echo "$PROMPT")
```

Each task gets a fresh kind cluster; exit 0 from verify.sh means pass. Ollama tuning (OLLAMA_MLX, multi-user cache, 32K context) is detailed in Post 6.

Quick note on what counts as a "pass": In Post 3, all frontier runs finished within a 10-minute timeout and a $5 budget—API-fast. Local inference ran slower, with five tasks exceeding those limits. I re-ran those with a 20-minute timeout and a $10 budget, changing nothing else. On the first try, 16 out of 24 tasks passed; with the relaxed limits, it was 21 out of 24. Air-gapped runs have no per-token cost, so patience is the only real limit. I'm reporting both results, but 21/24 is what counts.

## Results

| Scenario | Qwen3.6 + Skill | Sonnet 4.6 + Skill | Opus 4.6 (no Skill) |
|---|---|---|---|
| create-canary-deployment | PASS | PASS | PASS |
| create-network-policy | PASS | PASS | PASS |
| create-pod | **FAIL** | PASS | PASS |
| create-pod-mount-configmaps | PASS | PASS | PASS |
| create-pod-resources-limits | PASS | PASS | PASS |
| create-simple-rbac | PASS | PASS | PASS |
| debug-app-logs | PASS | PASS | PASS |
| deployment-traffic-switch | PASS | PASS | PASS |
| fix-crashloop | PASS | PASS | PASS |
| fix-image-pull | PASS | PASS | PASS |
| fix-pending-pod | PASS | PASS | PASS |
| fix-probes | PASS | PASS | PASS |
| fix-rbac-wrong-resource | PASS | PASS | PASS |
| fix-service-routing | PASS | PASS | PASS |
| fix-service-with-no-endpoints | PASS | PASS | PASS |
| horizontal-pod-autoscaler | PASS | PASS | PASS |
| list-images-for-pods | PASS | PASS | PASS |
| multi-container-pod-communication | PASS | PASS | PASS |
| resize-pvc | **FAIL** | PASS | **FAIL** |
| rolling-update-deployment | PASS | PASS | PASS |
| scale-deployment | PASS | PASS | PASS |
| scale-down-deployment | PASS | PASS | PASS |
| setup-dev-cluster | **FAIL** | **FAIL** | PASS |
| statefulset-lifecycle | PASS | PASS | PASS |
| **Total** | **21/24 (88%)** | **23/24 (96%)** | **23/24 (96%)** |

All models scored similarly, but each failed different tasks—no clear winner across the board. On an apples-to-apples test, the 35B laptop model trailed by just two scenarios, a smaller and less predictable gap than hardware specs suggest.

## The three it missed

### setup-dev-cluster — out of clock, not out of depth

This multi-tenant RBAC scenario also tripped up Frontier Sonnet. I expected the local model to struggle, but it didn't—Qwen3.6 generated the full build (six namespaces, three service accounts, twelve RBAC resources, six quotas, twenty-five network policies, plus setup and teardown scripts). However, it was still generating after 30 minutes, so I stopped it before verification. Result: no-score, not a clean fail—the manifests looked good, but nothing was verified.

The architecture was sound. By this point, context had exceeded the 32K limit, reaching 73K tokens, memory was within 1.45 GiB of the max, and per-turn latency ranged from 2–4.5 minutes. The issue wasn't reasoning — it was memory pressure, fixable by capping context, splitting the task, or better hardware.

### resize-pvc — the same wall frontier hit

In Post 3, this failed for every model, including frontier Opus: kind's local-path provisioner can't expand volumes. Qwen3.6 hit the same wall. The verifier issues the resize, then waits for the volume to actually report the new capacity—and on local-path it never does, so the wait runs until the 20-minute timeout. The timeout isn't the model running out of steam; it's the verifier correctly waiting on an expansion the provisioner can't perform. (The first attempt is a separate, mundane failure—it died on the $5 budget before reaching the resize at all.)

So this isn't a local-model weakness. It's an unwinnable scenario on kind, and Qwen3.6 failed it exactly the way the strongest frontier model did.

### create-pod — the trivial one it keeps failing

The simplest task: run a pod on nginx. The model did—right name, namespace, Running and Ready—but failed both attempts on one detail: it wrote nginx:latest, but the verifier matched only bare nginx:

```bash
if [ "$IMAGE" != "nginx" ]; then echo "Pod is using incorrect image: $IMAGE"; exit 1; fi
```

It's not confusion—the opposite. The model is more explicit than the verifier wants, appending :latest as a default and reporting it. It passes fix-rbac-wrong-resource and statefulset-lifecycle, then trips on a tag convention—a deterministic quirk to design around, not a reasoning gap.

### fix-crashloop — passed clean, nearly cheated

The pass was a real fix: keep the nginx image, replace the broken python3 command with nginx -g 'daemon off;'. Both failed attempts tried to swap in python:3.11-slim—the same verifier-gaming shortcut frontier Sonnet used in Post 3. The verifier checks readiness, not image identity; the swap would have passed had it finished. The successful run earned the pass. The instinct to game was present in the failures too.

## Speed is the tax

The median wall-clock time per task was 5 minutes 39 seconds, but the real bottleneck was per-turn latency. Each task required several back-and-forths; the median LLM turn took 53.7 seconds.

Frontier models finish most tasks in under a minute. Here, a single turn nearly hits a minute, and the toughest tasks stretched to 2–4.5 minutes per turn—so ten turns could mean half an hour on one task. That's what dragged down setup-dev-cluster.

But the slowness wasn't just inefficiency—it was resource starvation. Memory usage climbed steadily as the KV cache grew:

| Memory | Value |
|---|---|
| Model weights | 20.4 GiB |
| Session peak | 34.55 GiB |
| Machine total | 36 GiB |
| Headroom at peak | 1.45 GiB (4%) |

The peak came during the longest tasks, when context exceeded the 32K window and reached 73K tokens—MULTIUSER_CACHE packed with KV entries from earlier turns. With only 1.45 GiB of headroom left, the machine was under real strain, likely causing the per-turn slowdowns. The two failures and the general slowness both trace to this memory wall.

There was one bright spot: OLLAMA_KEEP_ALIVE=24h kept the model ready across tasks and overnight, with no reload needed. Cross-task and cold-start penalties were negligible—only the very first request paid the full prompt-processing price (63 seconds for a cache miss on 27K tokens).

In a later test, median time-to-first-token was 39.7 seconds, scaling with context—about 33s at low (<30K tokens), 44s at high (≥30K). That's almost a minute of waiting before output begins. I'm not reporting tokens/sec; Ollama doesn't reveal generation timing via the Claude Code endpoint, and dividing output by request time would just blur prompt processing with generation. TTFT and per-turn latency are what matter here—and both make the speed penalty felt.

## Tool calls hold up

The open question with a local model isn't just reasoning—it's whether the harness can reliably drive it. Malformed tool calls strand Claude Code, no matter how good the plan is. So I instrumented every tool call across thirteen fix-* and create-* scenarios: 120 Bash invocations, 104 of them kubectl.

One was malformed—a shell parse error from tricky single-quote escaping on kubectl patch. That's a 0.8% malformation rate, and the model recovered on the next turn by re-escaping. The harness drove the model cleanly; bad tool syntax doesn't break air-gapped operation.

That number deserves separation from a noisier one: eight other calls returned errors, but these were well-formed commands that did the wrong thing—a hardcoded clusterIP already in use, a probe for a missing StorageClass, repeated failed attempts to patch container args. Valid calls, wrong actions—reasoning misses, not harness failures. Combine both for a 7.5% error rate; separate them for a true read: the model's tool syntax is reliable, but tool judgment is where the misses are. Seven of nine total errors hit fix-crashloop—the one task needing a Python one-liner in a kubectl patch, a quoting gauntlet and exactly where you'd expect a slip.

No context-overflow events: nothing hit the token ceiling, even on the longest turn at 36K input tokens.

*(The tool-call and TTFT figures come from a focused 13-scenario instrumented run — the fix-\* and create-\* set — not the full 24.)*

## The verdict

Run a local air-gapped model if you need data sovereignty and can tolerate minutes-per-task latency. The capability is real: 21 of 24, just 2 behind the frontier, and tool calls are clean at a 0.8% malformation rate.

Don't, if speed is the priority. The local model is five to ten times slower per turn, and no tuning closes that gap on a laptop.

The trade is clear—you give up speed, not correctness. Every failure traced to time, memory, or the environment, never reasoning: correct RBAC manifests it couldn't generate fast enough, a volume the provisioner can't expand, a trivial pod task lost to a tag convention. The competence is real; the constraints are operational.

And the constraints are partly my hardware. An M3 Pro with 36 GiB is the floor for a 20 GiB model—the long tasks died at 34.55 GiB of memory, not at the edge of the model's reasoning. On an M3 Max or Ultra, setup-dev-cluster is likely to finish. The 21/24 is a floor set by my laptop, not a ceiling set by the model.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
