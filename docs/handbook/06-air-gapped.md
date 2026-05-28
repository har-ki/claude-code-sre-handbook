# 06 — Air-Gapped Claude Code
*The setup, the fixes that make it work, and the hardware that sets the pace*

Claude Code connects to a model running locally on the laptop. You provide a Kubernetes incident for investigation. After ten minutes, Claude Code times out before producing any results. The model didn't use any integrated tools—it spent the entire allowed session thinking.

It loads. It doesn't work yet.

Four fixes later, the same laptop took an incident from investigation to an open pull request — found the root cause, wrote the patch, pushed a branch, filed the PR with `gh` — with nothing leaving the machine. It took its time. But it closed the loop. The gap between loads and works is those four fixes, and once you clear them, the thing that separates a 34-minute session from a fast one is hardware, not approach.

Before we begin, here's what's ahead: a step-by-step setup, the four crucial fixes, and a clear explanation of how your hardware affects speed. Let's get started.

## Why local at all

One reason matters: data can't cross the firewall. In regulated environments and air-gapped clusters, a local harness isn't a preference—it's required. The good news: it works.

Everyone else is reading for the trade. Local buys you privacy and a flat cost. It bills you at latency and a model smaller than the frontier — but, as the completed loop above shows, capability is not what you give up on a task like this. Speed is. Whether that trade fits is what Part 2 answers across three posts. This one establishes what it takes to run, and what your hardware decides.

## The stack

State the rig. All numbers depend on it.

- **Hardware:** Apple M3 Pro, 18 GPU cores, 36 GiB unified memory, ~150 GB/s memory bandwidth.
- **Model:** `qwen3.6:35b-a3b-coding-nvfp4` — 35.1B parameters, mixture-of-experts with ~3B active per token, NVFP4 quantization. 21 GB on disk, ~20 GiB resident once loaded.
- **Runtime:** Ollama 0.24.0, MLX runner (Apple's Silicon-native backend, not the llama.cpp/Metal path).
- **Client:** Claude Code v2.1.84, pointed at the local Ollama endpoint.

MoE lets a 35B model run locally. Only ~3B active per token, so costs resemble a 14B dense model, while answers approach 35B. A dense 35B doesn't fit 36 GiB.

The tuned environment:

| Variable | Value | Why |
|---|---|---|
| `OLLAMA_MLX` | `1` | Use the Apple Silicon MLX runner, not the llama.cpp/Metal backend |
| `OLLAMA_CONTEXT_LENGTH` | `32768` | What 36 GiB allows — more memory raises this; see below |
| `OLLAMA_FLASH_ATTENTION` | `1` | Lower attention memory |
| `OLLAMA_MULTIUSER_CACHE` | `1` | Reuse the prefix cache across requests |
| `OLLAMA_KEEP_ALIVE` | `24h` | Keep the 20 GiB model resident; reloads are slow |

## From zero to a working session

Start to finish: assumes Apple Silicon and `kubectl` pointed to your cluster.

**1. Install Ollama, confirm the version.**

```bash
ollama --version   # must be 0.24.0 or newer — see fix #2 below
```

**2. Pull the model.** One-time, ~21 GB.

```bash
ollama pull qwen3.6:35b-a3b-coding-nvfp4
```

**3. Serve with the tuned environment.** Leave it running.

```bash
OLLAMA_MLX=1 \
OLLAMA_CONTEXT_LENGTH=32768 \
OLLAMA_FLASH_ATTENTION=1 \
OLLAMA_MULTIUSER_CACHE=1 \
OLLAMA_KEEP_ALIVE=24h \
OLLAMA_NO_CLOUD=1 \
ollama serve
```

For permanence, configure these in a launchd plist. Ollama runs as a service, not just your terminal.

**4. Point Claude Code at the local model and launch** from your working directory:

```bash
ANTHROPIC_BASE_URL=http://localhost:11434 \
MAX_THINKING_TOKENS=0 \
claude --model qwen3.6:35b-a3b-coding-nvfp4
```

No `ANTHROPIC_API_KEY` in the environment — not having this key is what makes Claude Code use the local model endpoint instead of contacting Anthropic's cloud service.

**5. First prompt — a smoke test, not the main event.** Pick something trivial that forces exactly one tool call:

> Run `kubectl get pods -A` and tell me if anything appears unhealthy.

What you'll see: the first tool call happens in a few seconds (when thinking is disabled), then you may wait about 60 seconds as the model performs prefill (prefill means loading all necessary input data such as the prompt and context into memory for the model to start generating responses, which for this setup is about 25,000 tokens). After prefill, you get the answer. Subsequent sessions ('turns,' or interactions between the user and the model) are faster because the prefix cache stores the static parts of the prompt so they don't need to be reloaded. The burst of 404 errors shown in the Ollama log during this process is normal (addressed in fix #4).

**6. Confirm nothing left the machine.** The server printed "Ollama cloud disabled: true" on boot; the base URL is localhost, and there's no API key set. The only traffic is loopback. That's the whole claim, verified.

Claude Code now investigates a real cluster using a model running entirely on your machine. What it can tackle on hard incidents—and how it compares to the frontier—comes in Part 2.

## The four fixes that make it work

These fixes make the setup work. Miss them and the setup stalls. None are in the quickstart. All are software, not silicon—they persist regardless of hardware.

### 1. Disable thinking — it spent the whole turn budget reasoning

qwen3.6 is a reasoning model. By default, Claude Code's thinking enabled meant the first turn spent its entire budget on an unbounded `<think>` chain. At ~5–8 tokens/sec, it kept reasoning until Claude Code's timeout. Result: a 10-minute first turn killed by timeout, no tool call emitted before dying. While I can't prove thinking blocks tool use, unbounded reasoning ran out the clock before tool use began on this hardware.

The fix is one env var: `MAX_THINKING_TOKENS=0`. A control test shows the scale — the same "what is 2+2" prompt took 128 thinking tokens and 6.7s with thinking on, versus 1 token and 0.6s with it off. With thinking disabled, the first tool call lands in seconds instead of never.

One caveat, kept honest: the suppression isn't airtight. A later session still emitted ~20K characters of reasoning on one turn despite the setting — either it wasn't applied to that session, or the model routed reasoning into normal output. Budget for it.

### 2. You need Ollama 0.24, not 0.20

Trying to bake settings into a Modelfile doesn't work for this model in Ollama 0.20. `ollama create` from an MLX base seems successful, but `ollama show` and the API both return "model not found." GGUF derivatives work; MLX derivatives fail. The manifest writes, but the server can't resolve it.

This is fixed in 0.24.0, which cleans up MLX safetensor model creation, routes the `think` parameter correctly through the OpenAI-compatible API, and reworks the MLX sampler. If you're on 0.20, upgrade before anything else — half the tuning levers don't exist until you do.

### 3. The MLX runner ignores your Modelfile template

Even on 0.24, disabling thinking via Modelfile fails silently. A custom template that strips `<think>` tags still returned 355 thinking tokens. The MLX runner uses its own renderer and parser (`qwen3.5`), overriding your template; thinking control is in the renderer, not the template.

The lesson is bigger than thinking: Modelfile knobs and llama.cpp habits do not transfer to the MLX path. Control thinking with the `think:false` API parameter or `MAX_THINKING_TOKENS=0` — not a template. Assume any llama.cpp-era tuning trick needs re-verifying on MLX before you trust it.

### 4. Ignore the 404 storm

Once running, logs show bursts of 18+ failed calls to `/v1/messages` and `/v1/messages/count_tokens` per request. Claude Code probes Anthropic-native endpoints Ollama doesn't handle. These 404s are fast and change nothing. Ignore them.

## The pace is set by hardware

With these fixes, it works. What matters now is your hardware.

| Metric | Observed (M3 Pro, 36 GiB) |
|---|---|
| Model resident | ~20 GiB (35B MoE, ~3B active, NVFP4) |
| Prefill rate | ~300–400 tok/s, falling toward ~270 as context fills |
| Prefill time at 25K input | 60–70s per turn |
| Per-turn time | dominated by prefill (90%+); generation is the small remainder |
| Peak memory, tuned and in-window | ~24.5 GiB |

The session is prefill-bound. Every turn re-reads the prompt — Claude Code's system prompt, tool definitions, `CLAUDE.md`, and the conversation so far — before generating a token. On this hardware, that's 60–70 seconds for a 25K-token turn, and prefill eats 90%+ of request time. As a shape: that completed 34-minute investigation-to-PR session spent roughly 20 minutes in prefill, 8 in generation, and 6 in tool execution. Slow — but it finished, correctly.

Here's the part that's really about the laptop. Prefill rate is set by memory bandwidth against a 20 GiB model, and the M3 Pro's ~150 GB/s is the floor. Higher-bandwidth Apple Silicon — the Max and Ultra tiers — raises that ceiling directly, because the bottleneck is bandwidth. Newer silicon helps the other half: Ollama's own MLX benchmarks on M5-class hardware show prefill and decode throughput climbing sharply over earlier chips, thanks to dedicated matrix-multiply units. None of that is a different approach. It's the same stack on a faster engine.

Only non-hardware lever: a smaller model completes prefill much faster. That's the next post's focus.

## The 32K window — and what more memory buys

The context window is 32,000 tokens. This is not chosen by preference, but by what fits in memory. Ollama sets the default context window based on detected GPU memory. In this case, a machine with 24–48 GiB of memory typically gets a 32,000-token window. Each token represents a piece of text the model can remember in context. The calculation: the 20 GiB model file leaves only a few GiB available for the KV cache (the key-value memory cache used by the model for fast access to data it uses often). A 32,000-token context window fills the remaining cache; a 64,000-token window would exceed available memory, making the system swap and slow down.

This is the clearest place hardware moves the line — but read the tiers carefully, because Apple Silicon has a catch. macOS exposes only part of unified memory to the GPU: on this 36 GiB machine, Metal saw 28.1 GiB, about 78%. Ollama's largest tier, which defaults to 256K context, triggers at 48 GiB of detected GPU memory — so a 48 GiB Mac never reaches it, because Metal only ever sees a fraction of the total. The practical tiers for this model:

| Unified memory | Default window | Experience |
|---|---|---|
| 36 GiB | 32K | Works; manage the window on long sessions |
| 48 GiB | 32K | Comfortable — clean 32K sessions, real headroom, no memory pressure |
| 64 GiB+ | 256K | The window stops being something you think about |

A 48 GiB Mac runs this well—same window, no memory strain. 256K context needs ~64 GiB unified memory.

Window size matters because real SRE work doesn't respect a small one. An agentic session that investigates and edits files quickly builds context. One such session on this laptop pushed the conversation to ~56K tokens — past the 32K window — and the runtime did what it must: evict and reprocess. The symptoms were unambiguous:

- KV cache thrashing — 600 MiB evicted at a time, reprocessed on the next turn.
- Cache hit rate collapsing to ~30%; the other ~70% re-read from scratch.
- Prefill stretching to 2–3 minutes per turn.
- Peak memory at 33.5 GiB — 93% of the machine — triggering OS memory pressure that slows everything, MLX included.

On 36 GiB, the rule is: keep sessions scoped, stay inside 32K, and run clean; sprawl past it, and you feel the thrash immediately. On a machine with the headroom for a 256K window, that rule mostly dissolves — the same session that overflowed here would stay resident there.

## What persists, what lifts, and who this is for

Sorted honestly by whether better hardware helps:

**Lifts with hardware:**

- Prefill speed — bandwidth-bound; Max/Ultra/newer silicon raises it.
- Context window — 32K on 36–48 GiB becomes 256K at 64 GiB+.
- Memory pressure — the 93% peaks vanish with headroom; gone by 48 GiB.

**Persists regardless of hardware:**

- Thinking suppression is fragile — budget for stray reasoning even with the flag set.
- MLX breaks llama.cpp habits — Modelfile and template tricks don't carry over.

Who should run this:

- **Anyone with an Apple Silicon Mac and ~48 GiB or more.** This runs comfortably — you get a working, fully local Claude Code that closes the investigation-to-PR loop, and at 48 GiB, the memory pressure is gone. 36 GiB works too; you just keep sessions scoped. 64 GiB and up, and the context window becomes a non-issue.
- **Teams sensitive to data leaving the firewall.** If cluster data and source can't cross the perimeter — regulatory, contractual, or policy — this is the door, and it works.

The completed run here was gated by a 36 GiB laptop, not by the approach. On a Mac with more memory and faster silicon, the limits I hit are the first ones to move. If you've got the hardware, this is worth trying — and I'd genuinely like to hear how it runs for you.

What this post deliberately doesn't settle is whether the local model is good enough at the work — setup and quality are different claims. The next post runs the same five Kubernetes incidents from earlier in the series on this exact stack and puts numbers on it, frontier versus local, side by side. The end-to-end demo that closes the loop gets its own full walkthrough later in Part 2.

---

The full setup notes, the environment file, and the raw Ollama logs behind every number here are in the repo at `shared/ollama-setup.md` — reproduce it on your own Apple Silicon box.

---

*Working through this on your own infrastructure? I help teams operationalize Claude Code for Kubernetes operations. [contact link]*
