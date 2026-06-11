# The Complete Watcher

*Everything from Part 3, assembled into one watcher you can clone and run on your own cluster.*

## Why this post

Part 3 built up context engineering one piece at a time: what to put in front of the agent ([runbooks](10-runbook-as-context.md)), how to make it connect signals instead of just gathering them ([correlation](11-correlation.md)), what happens when the context window fills ([the window edge](12-the-window-edge.md)), and how to stop the agent from being misled by its own memory ([memory](13-memory.md)).

Each was proven on its own. This post brings them together into one watcher — the [Post 5](05-building-the-always-on-watcher.md) watcher, now carrying everything Part 3 figured out — and ships it as a reference implementation you can actually deploy. It's [`watcher-capstone/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-capstone): clone it, point it at a cluster, and you have an always-on agent that watches for incidents, investigates them with memory and discipline, proposes a fix as a draft PR, and leaves an audit trail — with a human gate before anything ships.

**The takeaway, up front:** this is a complete, working starting point. It does the full loop — detect, investigate, propose a fix, remember what it learned — using only Claude Code as shipped and infrastructure you already run. The rest of this post covers what's in it, how it's built, how to run it, and the limits to know before you trust it.

**Setup:** Claude Sonnet 4.6 · the integration runs (storage parity, discipline-parity, concurrent-write) are measured on frontier; the watcher runs either model via config, but the committed results are Sonnet.

## What it does

The watcher runs the same loop a human on-call would, headless:

1. **Detects** — polls ClickHouse for a service whose error rate has crossed a threshold.
2. **Deduplicates** — fingerprints the incident and checks for an already-open PR, so it doesn't pile on.
3. **Investigates** — reads any past finding for this fingerprint, queries logs and traces, reads the source, and traces the error back to its cause. Writes its analysis into a draft PR.
4. **Proposes a fix** — a separate step reads the investigation, writes a minimal fix, commits it to the PR branch, and records what it learned to memory.
5. **Stops at the gate** — the PR stays a draft. A human reviews and decides.

Steps 3 and 4 are two separate agent invocations, never merged — the structural invariant from Part 1 that keeps each step's context clean. Every shell command the agent runs is filtered through an allow-list, and the command that marks a PR ready for merge is not on it. The human gate is enforced by what the agent *can't* do, not by asking it nicely.

## How it's built

The skeleton is unchanged from Parts 1 and 2. What Part 3 added, layered on:

- **A runbook as context** ([Post 10](10-runbook-as-context.md)). The SRE skill is built into the investigation prompt, so the agent starts with a procedure rather than a blank page.
- **Correlation** ([Post 11](11-correlation.md)). The investigation prompt tells the agent to read upward from the thrown error to its cause — the stack trace names where damage was detected, not where it started.
- **The memory loop** ([Post 13](13-memory.md)). Before investigating, the agent reads any prior finding for this fingerprint. After fixing, it writes back what it learned, as a required step.
- **Forced corroboration** ([Post 13](13-memory.md)). A recalled finding is a hypothesis to confirm against live evidence, never an answer to accept. This is the discipline that makes memory safe to use.
- **Two separate stores.** `memory-store/` is what the agent learned — it reads from and writes to it. `incident-store/` is what happened — human-readable reports and an audit log, written by the orchestrator, for people and compliance. The agent doesn't write its own audit trail.
- **Guardrails.** Memory filenames come only from a computed hash, checked against path traversal before any file is touched.

## The one genuinely new piece: swappable storage

Post 13 kept memory in a single text file. Easy and fine for a few hundred findings — but in production, it has a flaw: every save rewrites the whole file, so two incidents finishing at once can overwrite each other.

The capstone puts memory behind a small interface — `recall()` and `persist()` — with two backends: the original text file and SQLite. Both store the same embeddings and use the same similarity search, so the tradeoff is in writes, not retrieval. SQLite safely saves one record at a time and gives you a real way to query the store, all in a single file with no service to run. The interface is the actual lesson: the search logic and the discipline stay exactly the same; only the storage gets sturdier. Outgrow both, and you implement the same two functions over whatever's next.

Two honest notes, because the tests were honest:

**SQLite doesn't make search better.** It stores the same embedding and runs the same similarity comparison the text file did. At a few hundred findings, search is instant either way — a heavyweight vector database would solve a problem you don't have. SQLite's only advantages are safer writes and a queryable store.

**And I couldn't prove the safer-writes advantage on this watcher.** I wrote a test to make the text file lose a record during simultaneous writes and to show SQLite keeping both — but it didn't happen. In a single-watcher process, the pause to compute each embedding (about a tenth of a second) spreads writes out enough that the text file never collides. The flaw is real in principle, but in the way this watcher actually runs — one process, one incident at a time — it doesn't fire. So: the text file is genuinely fine for how this ships, and SQLite is insurance for a future where you run several watchers at once. I default to SQLite because safe writes are cheap insurance and a queryable store is handy — not because I can show you the text file failing.

## Quickstart

Three things have to be reachable first: a Kubernetes cluster with the otel-demo stack and ClickHouse (the same setup from [Post 5](05-building-the-always-on-watcher.md)), Ollama running locally with `nomic-embed-text` pulled (for embeddings), and an Anthropic API key plus a GitHub token.

**1. Seed the memory store** with the canonical finding and build the index:

```bash
cd watcher-capstone/
OLLAMA_URL=http://localhost:11434 ./seed-memory.sh
```

That uses the default SQLite backend. For the text-file backend instead:

```bash
OLLAMA_URL=http://localhost:11434 STORAGE_BACKEND=json ./seed-memory.sh
```

**2. Configure and start the watcher:**

```bash
cp .env.example .env
# edit .env: set ANTHROPIC_API_KEY and GH_TOKEN
docker compose up --build
```

Your kubeconfig is mounted automatically from `~/.kube/config`. The watcher begins polling ClickHouse and acts when a service crosses the error-rate threshold.

**3. Point it elsewhere**, if needed. The defaults assume a local rig; override per-run as needed:

```bash
# a different kubeconfig
KUBECONFIG_HOST=/path/to/kubeconfig docker compose up --build

# a different ClickHouse endpoint
CLICKHOUSE_HOST=clickhouse.example.com:9000 docker compose up --build

# Ollama on another host (used for embeddings at recall/persist time)
OLLAMA_URL=http://192.168.1.100:11434 docker compose up --build
```

The store backend, error-rate threshold, poll interval, and model are set in `alert-watcher/config.yaml`; the host-path and credential overrides are the environment variables above.

## Two limits worth knowing before you trust it

Honest limits travel with the artifact — adapt it knowing these, not after hitting them.

**It anchors on what memory says about your code.** In testing, when the running code differed from what a recalled finding described — a different file deployed than the one memory named — the agent could confirm the (real) bug memory pointed at, in the file memory pointed at, without noticing the pod was running something else. It happened in one of four runs; the other three checked what was actually deployed and caught it. The fix is a prompt rule, and it's a good one to carry into any memory-backed agent: *before trusting a recalled finding that names specific files or versions, verify that the live system is actually executing them.* Memory describes the past; the incident is in the present. (This is the same anchoring failure from [Post 13](13-memory.md), reaching one level further — into which artifact is deployed, not just what the cause is.)

**It reads its own memory, not your incident reports — on purpose.** The watcher reads one past: its own findings. The human-written reports in `incident-store/` sit right next to it, and it's tempting to feed those in too. The watcher doesn't, because incident reports are the more dangerous source — they sound authoritative, and they go stale, describing the system as it was when written. The anchoring above hits even harder with a confident six-month-old report. Reading reports as a second memory is a fair extension, but only behind the same corroboration discipline — arguably a stricter one. That's future work, not a tested behavior, so it's scoped out cleanly rather than shipped unproven.

Neither limit makes the watcher less deployable. They make it a reference implementation you can adapt with your eyes open — which is the point of shipping the code and the transcripts, not just the claims.

## That's Part 3

Context engineering isn't about the model or the harness. It's the work of building the picture the agent reasons from — what goes in, how you manage it as it grows, and the discipline that keeps the agent from trusting that picture further than it should. This watcher is that argument made deployable: runbook context, correlation, a memory loop with the discipline to use it safely, an audit trail, and storage you can grow into.

But notice what it doesn't do yet. It remembers — and that's all it does with the past. It can overwrite a good finding with a worse one. It has no way to tell a finding that led to a successful fix from one that didn't. It doesn't get better at investigating over time; it just accumulates notes. Remembering isn't learning.

That's Part 4 — the learning loop: turning a watcher that records the past into one that improves from it. How an agent should weigh a memory by whether the fix it suggested actually worked, prune what misleads, and sharpen its own investigation over time without drifting. The hardest version of the discipline this series has been building toward — and the start of a genuinely self-improving SRE agent.

---

The complete watcher and both storage backends are in [`watcher-capstone/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-capstone). Clone it, seed it, point it at your cluster, and watch it work an incident end to end.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](mailto:harikiran.nayak@gmail.com).*
