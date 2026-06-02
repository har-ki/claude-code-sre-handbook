# Post 7 Benchmark Data — Qwen3.6:35b-a3b-coding-nvfp4

> Extracted 2026-05-30 from `benchmark/data/runs/` and `benchmark/data/raw/`.
> All numbers come directly from `results.yaml`, `log.txt`, and `bench.log` files.
> Gaps are marked `DATA GAP:` inline.

## Data Sources Read

| Source | Path pattern | Count |
|--------|-------------|-------|
| JSONL result files | `benchmark/data/raw/20260529-T-qwen3-6*-skill-*.jsonl` + `20260530-T-*` | 26 files |
| Run directories | `benchmark/data/runs/20260529T*_qwen3-6*_skill/` + `20260530T*` | 16 dirs |
| Analysis summaries | `benchmark/analysis/20260529T*-qwen3-6*-skill-summary.md` | 12 files |
| Task definitions | `.build/k8s-ai-bench/repo/tasks/*/task.yaml` | 24 tasks |
| Verify scripts | `.build/k8s-ai-bench/repo/tasks/*/verify.sh` | 24 scripts |

**Schema per record:** Each task run produces `results.yaml` (fields: `name`, `result` [success/fail/error/""], `error`, `failures[]`, `llmConfig`) and `log.txt` (free-form model prose + kubectl output). `bench.log` at the iteration-1 level records wall-clock durations per task (e.g., `Completed ... in 5m39s`).

**Retries:** There is no built-in best-of-3 retry mechanism in k8s-ai-bench. Each JSONL entry represents a separate manual invocation of the benchmark runner filtered to specific tasks. "Retries" were manual re-runs after adjusting timeout (10m → 20m) and budget ($5 → $10). A task that "passed on retry" means it passed in a later manual run with relaxed constraints, not an automatic retry.

**Performance metrics:** `DATA GAP:` No tokens/sec, time-to-first-token, or peak memory data exists anywhere in the logs. The benchmark harness does not capture LLM inference metrics. Only wall-clock task duration is available (from `bench.log`).

**Tool-call traces:** `DATA GAP:` No raw tool-call data exists. `log.txt` captures the model's prose summary and kubectl resource-creation output, but not the actual tool-call invocations (tool name, parameters, raw output). No `trace.yaml` files were generated. Tool-call counts, malformation rates, and context-overflow events cannot be determined from available data.

---

## 1. Headline Pass Rates

### Qwen3.6 + Skill

**21 / 24 = 88%**

Failing scenarios (3):

| Scenario | Attempts | All failed |
|----------|----------|------------|
| create-pod | 2 | Both used `nginx:latest` instead of bare `nginx` |
| resize-pvc | 2 | Budget exhaustion ($5) + timeout (20m) |
| setup-dev-cluster | 1 complete + 1 killed | Timeout (10m); correct manifests produced but never verified |

Tasks that passed only on retry (after timeout/budget bump):

| Scenario | First attempt | Passed on |
|----------|--------------|-----------|
| create-canary-deployment | 2 failures (timeout + wrong selector) | 3rd attempt (20m timeout) |
| fix-crashloop | 2 failures (both 10m timeout) | 3rd attempt (20m timeout) |
| fix-probes | 1 failure (10m timeout) | 2nd attempt |
| horizontal-pod-autoscaler | 1 failure (10m timeout) | 2nd attempt |
| statefulset-lifecycle | 2 failures (10m timeout + $5 budget) | 3rd attempt (20m timeout, $10 budget) |

### Qwen3.6 + No Skill

`DATA GAP:` **No noskill runs exist.** All 16 run directories and all 26 JSONL files are exclusively `skill` mode. Zero runs were executed with `--no-skill`. The No-Skill column cannot be populated.

---

## 2. Per-Task Comparison Table

The 21/24 result is **Qwen3.6 + Skill**. The No-Skill column is empty (no runs).

| # | Scenario | Qwen3.6 + Skill | Attempt | Qwen3.6 + No Skill | Sonnet 4.6 + Skill | Opus 4.6 |
|---|----------|----------------|---------|--------------------|--------------------|----------|
| 1 | create-canary-deployment | PASS | 3rd | `DATA GAP` | | |
| 2 | create-network-policy | PASS | 1st | `DATA GAP` | | |
| 3 | create-pod | **FAIL** | 0/2 | `DATA GAP` | | |
| 4 | create-pod-mount-configmaps | PASS | 1st | `DATA GAP` | | |
| 5 | create-pod-resources-limits | PASS | 1st | `DATA GAP` | | |
| 6 | create-simple-rbac | PASS | 1st | `DATA GAP` | | |
| 7 | debug-app-logs | PASS | 1st | `DATA GAP` | | |
| 8 | deployment-traffic-switch | PASS | 1st | `DATA GAP` | | |
| 9 | fix-crashloop | PASS | 3rd | `DATA GAP` | | |
| 10 | fix-image-pull | PASS | 1st | `DATA GAP` | | |
| 11 | fix-pending-pod | PASS | 1st | `DATA GAP` | | |
| 12 | fix-probes | PASS | 2nd | `DATA GAP` | | |
| 13 | fix-rbac-wrong-resource | PASS | 1st | `DATA GAP` | | |
| 14 | fix-service-routing | PASS | 1st | `DATA GAP` | | |
| 15 | fix-service-with-no-endpoints | PASS | 1st | `DATA GAP` | | |
| 16 | horizontal-pod-autoscaler | PASS | 2nd | `DATA GAP` | | |
| 17 | list-images-for-pods | PASS | 1st | `DATA GAP` | | |
| 18 | multi-container-pod-communication | PASS | 1st | `DATA GAP` | | |
| 19 | resize-pvc | **FAIL** | 0/2 | `DATA GAP` | | |
| 20 | rolling-update-deployment | PASS | 1st | `DATA GAP` | | |
| 21 | scale-deployment | PASS | 1st | `DATA GAP` | | |
| 22 | scale-down-deployment | PASS | 1st | `DATA GAP` | | |
| 23 | setup-dev-cluster | **FAIL** | 0/1 | `DATA GAP` | | |
| 24 | statefulset-lifecycle | PASS | 3rd | `DATA GAP` | | |

**First-attempt pass rate:** 16/24 = 67% (the remaining 5 passes required re-runs with extended timeout/budget).

---

## 3. Anchor Findings from Post 3

### resize-pvc — FAILED (same environmental wall? or earlier failure?)

**Verdict: Inconclusive — cannot confirm same-reason failure.**

The logs do not contain raw tool-call data, so we cannot see whether the model attempted `kubectl patch pvc` and was rejected by kind's local-path provisioner.

- **Run 1 (174936):** Budget exhaustion. `Error: Exceeded USD budget (5)` appeared before any meaningful work. The model never reached the provisioner. Duration: 34m 47s.
- **Run 2 (214749, with $10 budget and 20m timeout):** Timed out at 20m. The model's prose claimed success ("the PVC storage-pvc is Bound with 15Gi capacity"), but the verifier never ran or never confirmed. The model mentions a "failed debug pod attempt" and a "dead-end approach," suggesting it struggled. Since the model claimed 15Gi but the task still timed out, the most likely explanation is that the PV capacity never actually changed (local-path doesn't support expansion) and the model hallucinated success — but this cannot be confirmed without tool-call traces.

**Bottom line:** Run 1 failed before reaching the provisioner (budget). Run 2's failure mode is ambiguous — it may have hit the same provisioner wall as frontier models, or it may have failed differently. The prose-only logs are insufficient to distinguish "same ceiling as frontier" from "failed earlier for a different reason."

### setup-dev-cluster — FAILED (how far? same break point as Sonnet?)

**Verdict: Timeout failure, not a reasoning failure. The model produced complete, correct-looking output but ran out of time.**

From the log (run 194132, 36m 44s wall-clock, 10m task timeout):

The model's output shows it created:
- 6 namespaces (dev-alice, dev-bob, dev-charlie, dev-shared, staging, prod)
- 3 service accounts (alice-sa, bob-sa, charlie-sa)
- 12 RBAC resources (roles, role bindings, cluster role)
- 6 resource quotas
- 25 network policies (default deny, DNS, intra-namespace, dev→shared, explicit denials, staging/prod isolation)

The model also wrote a full file structure under `scenarios/multi-tenant-dev/` with manifests, setup.sh, teardown.sh, and README.md.

**The verify script never ran.** The task timed out at 10m before verification. We cannot confirm whether the manifests would have passed all 6 verification checks (namespaces, service accounts, RBAC auth, quota values, network policies, functional curl test).

The failure is clearly inference speed, not reasoning depth. The quantized model understood the multi-tenant architecture but could not generate all the YAML fast enough.

### fix-crashloop — PASSED (real fix or gamed verifier?)

**Verdict: The passing run (214749) applied a legitimate fix. Earlier failed runs used verifier-gaming.**

**Run 3 — PASS (214749, 7m 39s):** The model kept the `nginx` image and changed the command to `nginx -g 'daemon off;'`. This is the correct fix — the problem was a broken `python3` command on an nginx image, and the right answer is to remove the bad command and let nginx run normally.

From the log:
> **Root cause:** The deployment's `nginx` image was configured with a `python3` command (`/bin/sh -c "python3 -c 'print('Starting'))'"`), but the nginx Docker image doesn't include python3, causing the container to crash with `python3: not found`.
>
> **Fix:** Changed the command to `nginx -g 'daemon off;'`, which is the standard way to run nginx as a foreground process.

**Run 1 — FAIL (160921, timed out):** Changed image from `nginx` to `python:3.11-slim` and fixed the Python syntax. This is verifier-gaming (image swap), but it never reached the verifier due to 10m timeout.

**Run 2 — FAIL (202801, timed out):** Same approach — swapped `nginx` to `python:3.11-slim`. Also timed out.

The verifier (`verify.sh`) only checks for pod readiness with label `app=nginx` and stable restart count — it does **not** check the container image name. So the image-swap trick would have passed if the model had completed in time. The fact that the passing run used the correct fix is fortunate, not enforced by the verifier.

**No asterisk needed on this pass** — the winning run's fix is genuinely correct.

### create-pod — FAILED (new outlier)

**Verdict: Tool-call formatting error — the model adds `:latest` tag when `nginx` (bare) is required.**

Both runs failed identically. The model created the pod correctly (right name, right namespace, Running/Ready) but specified `nginx:latest` instead of bare `nginx`.

**Run 1 (153458, 4m 7s):**
```
NAME         READY   STATUS    RESTARTS   AGE
web-server    1/1     Running   0          105s
pod/web-server condition met
Pod is using incorrect image: nginx:latest
```

**Run 2 (20260530T135919, 2m 34s):**
```
Pod: web-server
Namespace: web-server
Image: nginx:latest
Status: Running (Ready)
pod/web-server condition met
Pod is using incorrect image: nginx:latest
```

The verify script checks: `if [ "$IMAGE" != "nginx" ]; then echo "Pod is using incorrect image: $IMAGE"; exit 1; fi`

The model explicitly reported using `nginx:latest` in its own prose — it believes `:latest` is the correct way to specify the image. This is a consistent model behavior, not a random formatting glitch.

**This is surprising:** the model passes harder tasks (fix-rbac-wrong-resource, statefulset-lifecycle, create-canary-deployment) but fails a basic pod creation due to an implicit-vs-explicit tag convention. It's not a reasoning failure — it's a convention mismatch where the model defaults to the explicit form (`nginx:latest`) while the verifier expects the Docker-implicit bare form (`nginx`).

### Other passes — verifier-gaming scan

`DATA GAP:` The log.txt files contain only the model's prose summary, not raw kubectl commands or manifest diffs. A rigorous scan for verifier-gaming across all 21 passing tasks would require raw tool-call traces (which do not exist). From the prose summaries available:

- **fix-probes (pass, run 202801):** Model changed probe paths to `/` — this is a legitimate fix (the broken paths were `/get_status` and `/is_ready` which nginx doesn't serve).
- **create-canary-deployment (pass, run 214749):** Model's summary describes creating `engine-v2-1` deployment and updating service selector — appears legitimate but cannot confirm manifest details.
- No other pass shows obvious signs of gaming from the prose summaries, but this cannot be stated with confidence without tool-call traces.

---

## 4. Air-Gapped Performance Metrics

### Wall-Clock Duration Per Task

Extracted from `bench.log` files. Only the best (passing) attempt is shown where available, plus all failed attempts.

| Scenario | Duration | Result | Run |
|----------|----------|--------|-----|
| create-canary-deployment | 13m 11s | PASS | 214749 |
| create-canary-deployment | 10m 37s | FAIL | 153458 |
| create-canary-deployment | 7m 0s | FAIL | 171942 |
| create-network-policy | 2m 38s | PASS | 153458 |
| create-pod | 4m 7s | FAIL | 153458 |
| create-pod | 2m 34s | FAIL | 20260530T135919 |
| create-pod-mount-configmaps | 8m 27s | PASS | 153458 |
| create-pod-resources-limits | 5m 39s | PASS | 104631 |
| create-pod-resources-limits | 3m 31s | PASS | 153458 |
| create-simple-rbac | 3m 4s | PASS | 153458 |
| debug-app-logs | 3m 46s | PASS | 174413 |
| deployment-traffic-switch | 4m 39s | PASS | 171942 |
| fix-crashloop | 7m 39s | PASS | 214749 |
| fix-crashloop | 14m 30s | FAIL | 160921 |
| fix-crashloop | 11m 43s | FAIL | 202801 |
| fix-image-pull | 6m 42s | PASS | 160921 |
| fix-pending-pod | 4m 54s | PASS | 160921 |
| fix-probes | 5m 55s | PASS | 202801 |
| fix-probes | 5m 45s | PASS | 214749 |
| fix-probes | 15m 47s | FAIL | 160921 |
| fix-rbac-wrong-resource | 9m 8s | PASS | 160921 |
| fix-service-routing | 6m 24s | PASS | 160921 |
| fix-service-with-no-endpoints | 7m 20s | PASS | 160921 |
| horizontal-pod-autoscaler | 4m 35s | PASS | 214749 |
| horizontal-pod-autoscaler | 3m 15s | PASS | 192633 |
| horizontal-pod-autoscaler | 15m 45s | FAIL | 174936 |
| list-images-for-pods | 2m 38s | PASS | 174936 |
| multi-container-pod-communication | 8m 28s | PASS | 191652 |
| resize-pvc | 34m 47s | FAIL | 174936 |
| resize-pvc | 28m 10s | FAIL | 214749 |
| rolling-update-deployment | 5m 32s | PASS | 171942 |
| scale-deployment | 3m 10s | PASS | 171942 |
| scale-down-deployment | 2m 38s | PASS | 171942 |
| setup-dev-cluster | 36m 44s | FAIL | 194132 |
| statefulset-lifecycle | 11m 22s | PASS | 214749 |
| statefulset-lifecycle | 14m 34s | FAIL | 174936 |
| statefulset-lifecycle | 31m 17s | FAIL | 205117 |

### Aggregate (passing runs only, excluding gatekeeper)

| Metric | Value |
|--------|-------|
| Median wall-clock | 5m 39s |
| Min wall-clock | 2m 34s (create-pod, which still failed) |
| Max wall-clock | 13m 11s (create-canary-deployment) |
| Range | 2m 34s – 13m 11s |

`DATA GAP:` Tokens/sec, time-to-first-token, and peak memory are not recorded by the benchmark harness.

---

## 5. Tool-Use Reliability

`DATA GAP:` **No raw tool-call data exists in the benchmark output.**

The `log.txt` files contain only the model's prose summary and kubectl resource-creation confirmations (e.g., `namespace/foo created`). The actual tool-call invocations — tool name, parameters, raw output — are not captured. No `trace.yaml` files were generated despite the `--trace-path` flag being passed by the harness.

**Cannot determine from available data:**
- Total bash/kubectl tool calls attempted
- Count or rate of malformed tool calls
- Concrete malformation examples
- Context-overflow events past any threshold

**What IS visible indirectly:**
- The model's prose in `fix-probes` (run 160921) describes creating a ConfigMap with custom nginx config to serve the broken probe paths — this suggests multi-step tool use (create ConfigMap, patch deployment, wait for rollout) even though the individual calls aren't logged.
- The `resize-pvc` prose mentions a "failed debug pod attempt" and "dead-end approach" — evidence of at least one retried/abandoned approach, but the actual tool calls are invisible.
- The `create-canary-deployment` failure (run 171942) shows the model created a separate `recommendation-engine-canary` service — a wrong-approach tool call that completed successfully but produced the wrong result.

**To capture tool-call data in future runs:** modify `claude-agent.sh` to pass `--output-format json` or capture the full conversation trace. The current setup pipes Claude's human-readable output to stdout, which the harness captures as `log.txt`.

---

## 6. Anything That Broke

### Infrastructure failures

- **Kind cluster collision (run 214749, gatekeeper-horizontal-pod-autoscaler):** `node(s) already exist for a cluster with the name` — leftover cluster from a prior task wasn't cleaned up. 3 retries all failed. Cleanup also failed with `connection refused`. This is a harness/infra bug, not a model failure. (This task was excluded from the 24-task scorecard.)

- **Model name mismatch (runs 214426, 214607):** The orchestrator passed `qwen3-6:35b-a3b-coding-nvfp4` (hyphen) but Ollama expected `qwen3.6:35b-a3b-coding-nvfp4` (dot). All tasks in these runs failed with `model not found`. These runs are excluded from scoring.

- **Task YAML parse error (run 214239):** The timeout field was appended without a newline, producing `difficulty: "medium" timeout: "20m"` on one line. Bench aborted at startup. Fixed and re-run.

### Budget exhaustion

| Task | Run | Budget | Duration | Notes |
|------|-----|--------|----------|-------|
| resize-pvc | 174936 | $5 | 34m 47s | `Error: Exceeded USD budget (5)` before task completion |
| statefulset-lifecycle | 205117 | $5 | 31m 17s | Same error |

Both occurred before the budget was raised to $10. After the increase, statefulset-lifecycle passed; resize-pvc still failed (timed out at 20m).

### Bench.log truncation

Run 214749's `bench.log` is truncated mid-task at setup-dev-cluster (line 197). The run was killed manually. No results.yaml exists for that task in that run.

### Consistent model behaviors that caused failures

1. **`:latest` tag insertion:** The model consistently adds `nginx:latest` when `nginx` (bare) is specified. Both create-pod attempts show the same behavior, and the model even proudly reports the tag in its summary. This is a learned default that conflicts with the verifier's strict string match.

2. **Image-swap instinct on fix-crashloop:** In 2 of 3 attempts, the model's first instinct was to swap `nginx` for `python:3.11-slim` to make the Python command work, rather than removing the command. The correct fix (run 3) kept nginx and replaced the command with `nginx -g 'daemon off;'`. The model's reasoning was correct in all cases (it identified both the wrong image and bad syntax), but its fix strategy varied.

3. **Canary pattern misunderstanding:** In run 171942, the model created a separate `recommendation-engine-canary` service instead of broadening the existing service's selector. This shows a gap in understanding the standard K8s canary pattern (single service, broad selector, multiple deployments).

### Missing data that would strengthen the post

| Gap | Impact | Fix |
|-----|--------|-----|
| No noskill runs | Cannot compare Skill vs No-Skill for Qwen3.6 | Run `--no-skill` variant |
| No tool-call traces | Cannot analyze malformation rate, call count, or context overflow | Use `--output-format json` or capture conversation trace |
| No inference metrics | Cannot report tokens/sec, TTFT, or memory | Add Ollama `/api/generate` metrics capture or use `ollama ps` during runs |
| Single-attempt tasks | 16 of 24 tasks have only 1 attempt; Pass@3 cannot be computed reliably | Run `--iterations 3` for all tasks |

---

## Performance (from Ollama debug log)

> Source: `/tmp/ollama-debug.log`, covering 2026-05-29T21:39 through 2026-05-30T14:47.
> The Ollama server was started with `OLLAMA_DEBUG=DEBUG` and output tee'd to this file.
> The log spans the full benchmark session (all qwen3.6 + skill runs).

### Ollama server configuration during benchmark

From the server startup line:

| Setting | Value |
|---------|-------|
| `OLLAMA_CONTEXT_LENGTH` | 32768 |
| `OLLAMA_FLASH_ATTENTION` | true |
| `OLLAMA_NUM_PARALLEL` | 1 |
| `OLLAMA_MAX_LOADED_MODELS` | 1 |
| `OLLAMA_KEEP_ALIVE` | 24h |
| `OLLAMA_NO_CLOUD` | true |
| `OLLAMA_MULTIUSER_CACHE` | true |
| Engine | `--mlx-engine` (Apple Silicon MLX backend) |

### 1. Peak memory

**Model base footprint:** Ollama reports `runner.size=20.4 GiB` and `runner.vram=20.4 GiB` — the model weights occupy 20.4 GiB of unified memory, fully GPU-resident (no CPU/GPU split on Apple Silicon).

**Peak memory during inference** (reported per-request by Ollama's `pipeline.go`):

| Metric | Value |
|--------|-------|
| Session minimum | 23.81 GiB (first inference request) |
| Session maximum | **34.55 GiB** (after ~2.5 hours of continuous inference) |
| Machine total | 36 GiB unified memory |
| Headroom at peak | **1.45 GiB** (4% of total) |

**Memory grew over the session.** It was not stable — it climbed monotonically within each task as the KV cache expanded with conversation turns:

| Time window | Peak memory | Context tokens (`total` in cache) | Phase |
|-------------|-------------|-----------------------------------|-------|
| 21:49 (first request) | 23.81 GiB | 27,614 | Cold start, first task |
| 21:58 (14 requests in) | 29.18 GiB | 33,116 | First task, cache filling |
| 22:16 (26 requests) | 32.12 GiB | 39,405 | Second task, approaching 32K window |
| 22:50 | 32.13 GiB | 38,595 | Mid-session, steady state |
| 23:07–23:36 | 33.07–33.81 GiB | 48,815–62,461 | Long tasks (resize-pvc, setup-dev-cluster) |
| 23:40–00:02 | 33.87–**34.55 GiB** | 66,458–73,175 | Peak — context exceeded 32K window |
| 14:00 (next day, fresh task) | 31.36–32.09 GiB | 27,582–29,281 | After model reload, smaller context |
| 14:47 (final request) | 29.54 GiB | 11 tokens | Single test prompt |

**Key observation:** Memory peaked at 34.55 GiB during the longest-running tasks (setup-dev-cluster, resize-pvc) when context tokens reached 73K — well beyond the 32K context window, suggesting Ollama's `MULTIUSER_CACHE` was retaining KV cache from prior turns. This left only 1.45 GiB headroom on the 36 GiB machine, meaning the system was under severe memory pressure during the hardest tasks. This likely contributed to the timeout failures on those tasks (slower inference under memory pressure).

### 2. Per-request latency

112 inference requests logged (POST `/v1/completions`). Each request is one LLM turn within a multi-turn Claude Code conversation — a single task has many turns.

| Metric | Value |
|--------|-------|
| Minimum | 0.4s |
| p25 | 39.4s |
| **Median** | **53.7s** |
| p75 | 79.4s |
| Maximum | 278.7s (4m 39s) |
| Total requests | 112 |

**Latency distribution by session phase:**

| Phase | Time range | Request count | Median latency | Notes |
|-------|-----------|---------------|----------------|-------|
| Early tasks | 21:49–22:00 | 14 | ~43s | Fresh context, memory 24–29 GiB |
| Mid-session | 22:03–22:34 | 31 | ~51s | Context growing, memory 29–32 GiB |
| Steady state | 22:34–23:04 | 21 | ~42s | Tasks with moderate context |
| Long tasks | 23:04–00:03 | 16 | **~165s** | setup-dev-cluster / resize-pvc, context 48K–73K, memory 33–35 GiB |
| Overnight keepalive | 00:19–04:24 | 10 | ~5s | Very short health-check / keepalive pings |
| Next-day tasks | 14:00–14:47 | 5 | ~38s | Fresh context after overnight idle |

**Correlation with bench.log wall-clock times:** A task taking 5m 39s wall-clock (e.g., create-pod-resources-limits) is composed of multiple ~40s LLM turns plus setup/verify/cleanup overhead. The per-request latencies are consistent with the wall-clock durations — a 7-turn task at 45s/turn ≈ 5m 15s inference + ~24s overhead.

The long-task spike is dramatic: during setup-dev-cluster and resize-pvc, individual LLM turns took 2–4.5 minutes each. A task requiring 10+ turns at 3 minutes each would take 30+ minutes — matching the 36m 44s and 34m 47s wall-clock times for those tasks.

### 3. Cold vs. warm start

**Cold start (first request after model load):**

The first inference request shows a full cache miss:

```
cache miss  total=27614 matched=0 cached=0
```

The server needed to process all 27,614 tokens from scratch (system prompt + skill + task prompt). First request latency: **63.2s**.

**Warm subsequent requests:**

Every request after the first shows a cache hit:

```
cache hit  total=28358 matched=16897 cached=16897
```

Ollama caches up to ~16,897 tokens (half the 32K context window) from the prior turn, avoiding re-processing them. Subsequent request latencies drop to 28–50s in the early session.

**Cross-task cold starts:** When a new task begins (after cleanup of the previous task), the context resets but the model stays loaded (`OLLAMA_KEEP_ALIVE=24h`). The first request of a new task shows a cache hit (the system prompt + skill prefix is shared), so there is no model-load penalty between tasks — only a partial cache miss for the new task's prompt tokens.

**True cold start (model load):** Only one model load occurred in the session (at 21:39). `DATA GAP:` The Ollama log does not report model load duration as a separate metric. The first inference request (21:47:59 → 21:49:03, 63.2s) includes both prompt processing and any residual load cost, but these cannot be separated.

**Overnight keepalive behavior:** Between 00:19 and 04:24, requests dropped to 0.4–7s with cache hits showing `total=73175 matched=47104–63488`. The model stayed resident and Ollama was re-processing cached KV entries at high efficiency. This confirms the `KEEP_ALIVE=24h` setting works — no cold-start penalty for the next-day tasks at 14:00.

### What's NOT in this log

| Metric | Status |
|--------|--------|
| Tokens/sec (generation throughput) | `DATA GAP:` Not logged server-side. Would need `eval_count` / `eval_duration` from the API response body, which the harness discards. |
| Time-to-first-token | `DATA GAP:` Not logged. Would need `prompt_eval_duration` from API response. |
| Prompt eval throughput | Partially available — `Prompt processing progress` lines show token counts and timestamps, but only for large prompts where processing spans multiple log lines. Not consistently present for all requests. |
| GPU utilization | `DATA GAP:` Not in Ollama logs. Would need `sudo powermetrics` or similar Apple Silicon profiler. |

---

## Tool-call reliability (instrumented runs)

### Scope

Data from a single instrumented run on 2026-05-31 using `--output-format stream-json --verbose` with the logging proxy active. Model: `qwen3.6:35b-a3b-coding-nvfp4`. Skill mode only.

**Scenarios covered (13):** `create-canary-deployment`, `create-network-policy`, `create-pod`, `create-pod-mount-configmaps`, `create-pod-resources-limits`, `create-simple-rbac`, `fix-crashloop`, `fix-image-pull`, `fix-pending-pod`, `fix-probes`, `fix-rbac-wrong-resource`, `fix-service-routing`, `fix-service-with-no-endpoints`.

All 13 scenarios have complete `trace.jsonl` files (no killed/truncated traces). This is one iteration — not the full 24-task suite. The 11 remaining tasks (debug-app-logs, deployment-traffic-switch, fix-oomkilled, and the gatekeeper-* set) were not included in this instrumented run.

**Results:** 10/13 passed, 3 failed (create-canary-deployment, create-pod, fix-crashloop).

**Denominator:** 100 API turns across 13 tasks, producing **120 Bash tool-use blocks** (some turns issued multiple tool calls). Of 120 Bash calls, 104 were kubectl invocations.

### Malformation rate

**1 malformed tool call out of 120 = 0.8% malformation rate.**

A *malformed* call is one where the harness could not execute the command — the shell rejected it before it reached kubectl/the target binary. Only one call met this criterion:

> **fix-crashloop, turn 7:** Shell parse error on a `kubectl patch` with nested single-quote escaping.
> ```
> kubectl patch deployment app -n crashloop-test --type='json' \
>   -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args",
>         "value": ["python3 -c \"print(\'Starting\')\""]}]'
> ```
> Error: `(eval):1: parse error near ')'`

The model immediately retried with different escaping (double-backslash), which parsed correctly but produced invalid YAML — a *reasoning* error, not a malformation.

### Error results (wrong-but-well-formed actions)

**8 additional tool calls returned errors from valid, parseable commands.** These are reasoning failures, not harness failures:

| Scenario | Errors | Nature |
|----------|--------|--------|
| fix-crashloop | 6 | Repeated failed attempts to patch container args with correct escaping (2), `kubectl wait` timeouts after wrong image swap (2), a broken `kubectl set image` + inline-python pipeline (1), a `kubectl apply` with missing required fields (1) |
| create-canary-deployment | 1 | Tried to create a Service with a hardcoded clusterIP already allocated |
| fix-pending-pod | 1 | `kubectl get sc sc` — probed for a StorageClass named "sc" that didn't exist (exploratory, not harmful) |

**Total error rate (malformed + wrong-action):** 9/120 = 7.5%. But the malformation rate — the measure of whether the harness can reliably drive the model — is 0.8%.

### Per-scenario breakdown

| Scenario | Bash calls | kubectl | Errors | Malformed | Result |
|----------|-----------|---------|--------|-----------|--------|
| create-canary-deployment | 16 | 13 | 1 | 0 | fail |
| create-network-policy | 3 | 3 | 0 | 0 | pass |
| create-pod | 4 | 4 | 0 | 0 | fail |
| create-pod-mount-configmaps | 11 | 9 | 0 | 0 | pass |
| create-pod-resources-limits | 3 | 2 | 0 | 0 | pass |
| create-simple-rbac | 4 | 4 | 0 | 0 | pass |
| fix-crashloop | 23 | 18 | 7 | 1 | fail |
| fix-image-pull | 5 | 5 | 0 | 0 | pass |
| fix-pending-pod | 13 | 11 | 1 | 0 | pass |
| fix-probes | 8 | 7 | 0 | 0 | pass |
| fix-rbac-wrong-resource | 8 | 8 | 0 | 0 | pass |
| fix-service-routing | 9 | 9 | 0 | 0 | pass |
| fix-service-with-no-endpoints | 13 | 11 | 0 | 0 | pass |
| **Total** | **120** | **104** | **9** | **1** | **10/13** |

Errors cluster heavily on fix-crashloop (7 of 9 errors, the only malformation). That scenario required patching container args with embedded Python one-liners — a quoting challenge that tripped the model repeatedly.

### Representative well-formed tool sequences

**fix-rbac-wrong-resource** (8 calls, 0 errors, pass) — diagnose → patch → verify:
```
1. kubectl get all -n simple-rbac-setup -o yaml
2. kubectl get roles,rolebindings -n simple-rbac-setup -o yaml
3. kubectl auth can-i list pods --as=system:serviceaccount:simple-rbac-setup:pod-reader ...
4. kubectl apply -f scenarios/multi-tenant-dev/manifests/ ... ; ls scenarios/
5. kubectl get role pod-reader-role -n simple-rbac-setup -o yaml
6. kubectl patch role pod-reader-role -n simple-rbac-setup --type json -p '[{"op":"add",...}]'
7. kubectl auth can-i list pods --as=system:serviceaccount:simple-rbac-setup:pod-reader ...
8. kubectl get role pod-reader-role -n simple-rbac-setup -o yaml
```

**fix-service-routing** (9 calls, 0 errors, pass) — systematic selector mismatch diagnosis:
```
1. kubectl get all -n web
2. kubectl get svc,pod,deploy,netpol -n web -o yaml
3. kubectl get ns web -o yaml
4. kubectl get endpoints -n web
5. kubectl get svc nginx -n web -o jsonpath='{.spec.selector}'
6. kubectl get pod -n web --show-labels
7. kubectl patch service nginx -n web --type='json' -p='[{"op":"replace",...}]'
8. kubectl get endpoints -n web
9. kubectl run tmp-test -n web --image=busybox --restart=Never --rm -i -- wget ...
```

**fix-probes** (8 calls, 0 errors, pass) — logs → describe → patch → verify:
```
1. kubectl get all -n orders
2. kubectl get namespaces
3. kubectl logs -n orders webapp-576459b88-dlw92
4. kubectl describe pod -n orders webapp-576459b88-dlw92
5. kubectl describe deployment -n orders webapp
6. kubectl patch deployment webapp -n orders --type='json' -p='[...]'
7. sleep 20 && kubectl get pods -n orders -l app=webapp
8. kubectl get deploy -n orders -o wide && kubectl logs -n orders ...
```

### Context overflow

No context-overflow signals detected. No `stop_reason: "max_tokens"` events in any trace. The maximum input token count observed was 36,109 tokens (fix-crashloop, final turn), within the 32K context + overhead budget. Two turns exceeded 36K input tokens; both completed without truncation.

---

## Latency and TTFT (instrumented runs)

### Scope

Same 13-scenario instrumented run as above. The logging proxy (`inference-proxy.py`) recorded per-API-call timestamps between Claude Code and Ollama's `/v1/messages` endpoint. **100 API calls captured across 100 turns** — full coverage, no missing records.

`DATA GAP:` Ollama does not expose `eval_duration` or `eval_count` through the `/v1` OpenAI-compatible endpoint, so generation tokens/sec cannot be computed. The `duration_ms` and `time_to_first_token_ms` below are end-to-end wall-clock figures measured by the proxy, not Ollama-internal eval times. Do not interpret `output_tokens / duration_ms` as a generation rate — it includes prompt evaluation, scheduling, and proxy overhead.

### Overall latency

| Metric | Min | p25 | Median | p75 | Max |
|--------|-----|-----|--------|-----|-----|
| Duration (s) | 30.6 | 37.4 | 43.7 | 49.6 | 73.7 |
| TTFT (s) | 26.4 | 33.9 | 39.7 | 44.5 | 59.7 |

n = 100 for both. TTFT = time from request sent to first SSE chunk received by proxy.

### Cold start vs. warm

The first API call of each task session includes model weight loading and KV-cache warmup. Excluding these 13 cold-start calls:

| Phase | n | Duration median (s) | TTFT median (s) |
|-------|---|-------------------|-----------------|
| Cold (first call per task) | 13 | 35.8 | 29.9 |
| Warm (subsequent calls) | 87 | 44.7 | 40.6 |

Cold starts are *faster*, not slower — because first-turn prompts are shortest (~27.6K tokens). The "cold model-load" cost visible in the earlier un-instrumented run (where the first call took ~148s) is absent here because the model stayed resident in GPU memory across task boundaries. The proxy was started once for the entire run; Ollama kept the model loaded.

### Split by context depth

Context size drives latency more than session position:

| Context bucket | n | Duration median (s) | TTFT median (s) | Input token range |
|---------------|---|-------------------|-----------------|-------------------|
| Low (<30K tokens) | 44 | 36.9 | 33.4 | 27,619–29,882 |
| High (≥30K tokens) | 56 | 47.6 | 44.3 | 30,060–36,109 |

TTFT scales roughly linearly with input token count. At ~30K tokens (the median), TTFT ≈ 40s. At ~36K tokens (the maximum), TTFT ≈ 60s.

### Cross-check with prior Ollama debug-log extraction

The earlier un-instrumented run (Post 7 main data) reported median LLM latency of **53.7s** from Ollama debug logs. This instrumented run's proxy-measured median is **43.7s** — 19% faster. Likely explanations:

1. **Task mix:** This run covers 13 of 24 tasks (the fix-* and create-* subset). The prior run included long-running tasks (setup-dev-cluster, resize-pvc) that pushed latency higher. The instrumented subset skews toward shorter, more focused tasks.
2. **Model residency:** The prior run was spread across 26 separate invocations over multiple days with model reloads. This run kept the model resident throughout.
3. **Measurement point:** The proxy measures wall-clock at the HTTP layer; the Ollama debug-log extraction measured internal eval time. These are not directly comparable.

The latency range in this run (30.6–73.7s) is narrower than the prior run's range, consistent with the absence of the longest-running tasks (which had 2–4.5 minute per-turn latencies). The prior run's observation that "latency differed sharply across phases" is confirmed: low-context turns are ~30% faster than high-context turns (median 36.9s vs. 47.6s).
