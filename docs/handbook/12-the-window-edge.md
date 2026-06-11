# The Window Edge

*Your agent thinks it has 200K of room. It has 32K. That gap is where good investigations go to die.*

Claude Code won't compact a local model's context because it thinks the window is 200K when it's actually 32K. One environment variable fixes this. Here's how far that fix goes.

**Setup:** Local Qwen3.6 (`qwen3.6:35b-a3b-coding-nvfp4`) on Ollama, `num_ctx=32768`, on an M3 Pro with 36GB. Claude Code v2.1.84. One task: `fix-crashloop` from k8s-ai-bench, with the Kubernetes skill loaded. I chose the local model on purpose—this window issue only appears when the window is small, and 32K is small enough to hit in a single incident. With a frontier model, you rarely hit this limit. That difference is key.

## Why the window is the thing that matters

An agent only reasons well with what's inside its context window. A coding agent debugging an incident fills that window fast—every kubectl output, log line, and file it reads gets added to the conversation. If you let it grow unchecked, the session runs past the window's edge, and the model loses the early context it needs to link causes and effects. It keeps answering, but now it's missing pieces it can't see. If you manage the window, the agent keeps a clear picture. If you don't, the picture quietly falls apart.

This series breaks context engineering into three choices: what to put in the window, how to manage it as it grows, and how the agent reasons over what's inside. Earlier posts covered the first step—using runbooks and signals to get the right things into the window. This post tackles the second step, the one people often skip, and follows it from setup to failure to fix.

People skip this step because it seems automatic—the harness should handle compaction. On a frontier model, this mostly works; the window is so big you rarely hit its limit in one incident. But when you use a self-hosted model, that assumption breaks. The window is small and fills quickly, and the harness doesn't step in. Now, managing the window is something you must configure. That's why this decision matters, and why it's the first thing to break when you leave frontier models behind.

## What goes wrong: the harness is watching the wrong number

Claude Code has a feature called auto-compaction. When a session gets long, it summarizes earlier parts of the conversation so important details stay in view and the rest gets compressed. On a frontier model, this happens quietly, and you don't have to worry about it.

Run the same Claude Code against a local model, and compaction stops happening. It's not that local models can't compact—they can. But Claude Code never decides it's time. It's waiting for the window to fill, but by its own count, the window never fills.

Here's why. Claude Code maintains an internal table of each model's context window size. For this local model, that table reports a window of around 200,000 tokens, and auto-compaction won't trigger until the conversation gets deep into it — by default, compaction fires around 90% of the believed window, so roughly 180K. But Ollama is actually running the model with a 32,768-token window — that's what a 36GB machine affords once you account for the model weights and KV cache. Claude Code doesn't ask Ollama for the real number. It trusts its table.

So auto-compaction is watching for an 180K threshold inside a 200K window that doesn't exist. The conversation climbs past 32K — the real limit — and Claude Code keeps sending the full, uncompacted history at every turn, because, by its own count, it's nowhere near the line.

This isn't a Claude Code bug. It's a configuration mismatch: a generic default meets a model that doesn't match. The fix is to tell Claude Code the real window size. The next section shows what happens before you do that.

## What the failure looks like

I ran `fix-crashloop` twice on the same machine, with the same task and model. The only difference: one run had the window override set, one didn't.

**Run A — no override.** This is the default behavior, the one most people hit first.

The conversation kept growing. Input tokens rose each turn—28K, 30K, 32K, 34K—straight past the real 32K window with no compaction anywhere in the trace. By the end, it hit 36,195 tokens, well over the 32,768-token window.

You can see the consequence on the Ollama side. Every request Claude Code sent, Ollama logged its size. Once the conversation crossed 32K, every request was too big for the window:

```
cache hit total=32191   ← over the 32K window
cache hit total=33627
cache hit total=34419
cache hit total=35560   ← peak, 108% of the window
```

Ten of the 24 requests in Run A were too large. Ollama doesn't reject them—it cycles tokens through the cache, evicting older ones to make room. But the evicted tokens are ones the model can't use when generating. The model is reasoning with gaps in its context and doesn't know it.

The run never converged. It took 28 turns, spawned three subagents, tried different fixes, and the harness killed it at the 20-minute timeout. It failed.

## How to fix it

**Run B — one variable set:**

```bash
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=32768
```

That tells Claude Code: the window is 32,768, not 200,000. Now, auto-compaction monitors the correct number and can fire at the right time.

The difference is immediate. Compaction fired four times during the run. Each time, Claude Code summarized the older conversation and the token count dropped back down. Instead of climbing forever, the session settled into a steady band between 28.4K and 28.9K and stayed there:

| | Run A (default) | Run B (override) |
|---|---|---|
| Token trend | grows to 36,195 | flat, ~28.4K–28.9K |
| Compaction events | 0 | 4 |
| Requests over 32K | 10 of 24 | 0 of 8 |
| Peak request size | 35,560 (108%) | 30,015 (92%) |
| Outcome | failed (20-min timeout) | passed (8.3 min) |

The part that matters most: the fix reached Ollama. This was the question I most wanted answered, because it's easy to imagine a fix that looks good in Claude Code's own numbers but changes nothing on the wire. Compaction summarizes Claude Code's copy of the conversation — but does that actually mean smaller requests hit the model? It does. Run B's requests to Ollama stayed under the window the whole time, peaking at 30,015 tokens — 92% of 32K. After each compaction, you can watch the request size drop in Ollama's own log:

```
cache hit total=28838
cache hit total=27609   ← dropped, just after a compaction
cache hit total=30015
cache hit total=28144   ← dropped again
```

This is the real result, and it holds independent of anything else: with the override, Ollama never sees an oversized request. Without it, most requests are oversized. The fix is genuine, not cosmetic, and the next question is whether the model loses the thread.

### Did the model lose the thread?

A fair worry: if you keep summarizing the conversation, does the agent forget what it was doing? In this run, it didn't. After each compaction, the model picked up cleanly. Reading its reasoning right after a summary, it still knew it had applied a fix and needed to verify it, and at the end it correctly read its own compacted summary and concluded the task was done. It found the root cause (an nginx image running a python3 command), removed the bad command, confirmed the pod came up healthy, and reported success. The summaries kept the diagnostic chain intact.

But read that carefully: in this run. `fix-crashloop` is a short, single-cause incident — the diagnostic chain is shallow, and the context that mattered was all recent, exactly the context a summary keeps. That's the easy case for compaction. The hard case comes next.

### Two routes to the same fix, and a warning

There are two ways to set up compaction:

* Set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` to your model's real window size (the direct approach I used), or
* Use `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` to set the compaction trigger as a percentage of the default (~180K), calculated as `(real_num_ctx / 180000) * 100`.

Both methods aim to trigger compaction before exceeding your true window. Don't use both unless you understand their interaction—choose one and apply it correctly. The key is to base the percentage on the default window size, not your actual window.

### Reproduce it

Both runs use the same benchmark command. The only difference is the environment variable.

The failing default — no override:

```bash
./benchmark/bin/run-k8s-ai-bench.sh \
    --model "qwen3.6:35b-a3b-coding-nvfp4" \
    --skill \
    --task-pattern "fix-crashloop" \
    --iterations 1
```

The fix — set the window to your model's real context length first:

```bash
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=32768

./benchmark/bin/run-k8s-ai-bench.sh \
    --model "qwen3.6:35b-a3b-coding-nvfp4" \
    --skill \
    --task-pattern "fix-crashloop" \
    --iterations 1
```

To watch the fix reach the model server, run Ollama with debug logging and grep for request sizes:

```bash
OLLAMA_DEBUG=1 OLLAMA_CONTEXT_LENGTH=32768 ollama serve 2>&1 | tee /tmp/ollama.log
# in another shell, after a run:
grep "cache hit" /tmp/ollama.log   # watch total= stay under 32768 with the override
```

To confirm compaction actually fired, look for `compact_boundary` events in the run's `trace.jsonl`. Full token traces and the A/B comparison behind every number here are in `benchmark/analysis/compaction-tuning-findings.md`.

## Where this stops working

This is a real fix, but it's a narrow one, and I'd rather tell you the edges than let you find them in production.

**It's tuned to a tight window.** The Kubernetes skill plus the system prompt already eat about 87% of a 32K window before the first user message. That leaves very little room, so compaction has to fire early and often. On a 64K window, the same skill would use about 43%, compaction would fire later and less often, and the override would matter less. The smaller your window, the more this matters.

**Compaction fires late, by design.** It triggers at ~28K, not at some lower number you might pick, because the token count is checked after a turn finishes — after the model's latest tool output has already been appended. On a task with very large tool outputs, a single turn could push past 32K before the check runs. If your tool outputs are large, set the override to a value lower than the real window to leave headroom.

**Compaction is lossy.** Especially with a small window, it aggressively summarizes past turns, sometimes losing important early details that may be needed later. This creates two risks: if compaction happens too late, the window overflows; if too often, key context is lost. On short incidents, this isn't a problem, but in longer, complex cases, aggressive compaction can hide critical evidence. This trade-off is explored further in the next post.

**The model can still choke.** In one run, after several successful compactions, the prompt became too long and caused an error. This is a known issue, especially with local models and smaller context sizes. Staying under the window limit helps, but doesn't guarantee success. If errors persist, you may need to disable auto-compaction and clear the session manually.

**The task-outcome win is one data point.** While the override consistently keeps requests under 32K, I can't claim it always fixes the task based on a single result. The mechanism is proven, but the task improvement is only suggestive—consider the time savings as an illustration, not a benchmark.

**The override doesn't fix the root number.** Setting `CLAUDE_CODE_AUTO_COMPACT_WINDOW` corrects the compaction trigger, but Claude Code's table still says 200K. Anything else that reads that number is still reading the wrong one. This patches the symptom that bites hardest; it doesn't correct the registry.

## The takeaway

If you're running Claude Code against a local model, do this:

1. Find your model's real context window—it's whatever `num_ctx` (or `OLLAMA_CONTEXT_LENGTH`) Ollama actually uses, not what Claude Code reports.
2. Pick one route. Either set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` to that real number (what I did), or set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` to roughly `(real_num_ctx / 180000) * 100`. Both make compaction fire while the conversation still fits. Don't set both and assume they compose.
3. Restart Claude Code — these variables are read at startup.
4. If your tool outputs are large, leave some headroom—set the window override a few thousand below the real window, so the last turn before compaction doesn't overshoot.
5. Confirm it worked by looking for `compact_boundary` events in the trace, or by watching request sizes in your model server's logs stay under the window.

Setting one variable to your real window size turns a session that grows until it breaks into one that stays steady.

The main takeaway: the context window is your real limit, especially with small, local models. Unlike frontier models, you must manage the window yourself—but the solution is just one configuration line.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
