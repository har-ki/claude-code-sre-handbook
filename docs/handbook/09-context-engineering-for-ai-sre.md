
# 09 — Context Engineering for AI SRE

*The gap isn't the model — it's the reality you present to it.*

Context engineering is the deliberate shaping of what enters a model's context window — and what stays out. The model is fixed at inference; context is your lever. It is not about managing token limits or window sizes — that's plumbing. The work is in the choices: which system instructions, tool definitions, retrieved data, conversation history, memories of prior interactions, and output constraints to include. Each claims space in a limited window and competes for the model's attention.

More isn't better. The tension is between relevance and completeness: too little, and the model misses what matters; too much, and the signal drowns in noise, costs rise, and the model fixates on whatever's in front of it. The failures are concrete — stale context, irrelevant detail crowding out what's relevant, and misplaced trust in data that no longer holds. What you put in shapes the model's thinking; what you leave out defines its blind spots.

For AI SRE, that practice comes down to four things you put in front of the agent: a model of the environment (what depends on what, what changed), the evidence to investigate with (logs, traces, metrics), memory of past incidents, and a discipline for how it treats what it recalls. The rest of this post maps these onto the watcher built in this series and shows what Part 3 proves about each.

Parts 1 and 2 built a watcher that investigates incidents, proposes fixes, and opens draft PRs — headless, in five minutes, for $0.62. It works, but it handles each incident in isolation: no memory of past resolutions, no persistent model of the environment, and no systematic way to reason about what it finds. A human SRE doesn't operate this way. Nor does a production-grade tool.

The gap isn't the model — Sonnet 4.6 can already reason well. Nor is it the harness — `claude -p` with `--allowedTools` is mechanically sufficient. The difference is in what goes into the context window before the model reasons, and the discipline that governs how it interprets what it finds.

## What was missing

The Post 5 watcher's working reality is limited to the current alert's error rate, recent ClickHouse logs, current kubectl output, and the workspace source code. That's often enough to diagnose incidents cold — as Parts 1–2 showed — but it falls short of what a human SRE brings: persistent knowledge, environmental context, prior findings, and disciplined reasoning. Four levers, each a gap.

**A system model** — environment grounding. The topology of what talks to what, where telemetry lives, what changed recently. A human knows that `ecommerce-api` depends on an in-memory inventory store, that product 7 has limited stock, that the load generators scale concurrency. The watcher discovers this from scratch every time. It's the standing context that orients an investigation before the first log query. Tools like Traversal aim to build this grounding layer — a standing causal graph of the environment the agent reasons against, rather than just the telemetry from this moment.

**Multi-signal evidence** — logs, traces, metrics, deploy history, cross-referenced rather than queried in isolation. The watcher gathers several of these but doesn't yet correlate them over time or against deploy history. (More on what it does and doesn't do below.)

**Memory of prior resolutions** — the root cause and fix pattern that should be available next time the same fingerprint fires. The same `StockMismatchError` occurs under the same race condition, and the agent rediscovers the TOCTOU bug from scratch. The prior finding exists — the agent just can't see it.

**A discipline for treating what it recalls.** When a finding is surfaced, how does the agent treat it? Does it accept it and stop looking, or corroborate it against current evidence? The answer determines whether memory helps or misleads.

These four are not equally hard or equally proven. This series built and tested two of them (memory and discipline), partially addressed a third (evidence gathering, without full correlation), and mapped the fourth (environment grounding) as deliberate future work.

## What this series built vs. mapped

**Partially built: multi-signal evidence.** The watcher gathers from multiple sources — logs and traces from ClickHouse, pod health from kubectl, source code from the repo. Post 2's transcripts show the agent reading trace timelines alongside error logs, then reading source to confirm the mechanism. That's multi-source gathering, and it's real. What it doesn't do is correlate those signals over time and onto a causal timeline — the difference between "the error rate is 50%" and "the error rate rose from 2% to 50% after commit abc123." The gathering is demonstrated; the temporal and causal correlation is the unbuilt, harder part.

**Built and proved: memory and discipline.** [Post 10](10-memory-for-the-sre-loop.md) builds durable incident memory into the watcher. It works for exact repeats and breaks on partial matches — a partial match being a recalled finding that's genuinely relevant but incomplete for the current incident (same signature, different or additional root cause).

[Post 11](11-similarity-search-and-validation-discipline.md) adds two interventions that solve different failures. Better retrieval (similarity search) fixes the *recall* problem — it finds the right result when the incident signature has drifted and exact hashing can't reach it. A reasoning discipline fixes the *trust* problem — it governs how much weight the agent gives a recalled finding, requiring corroboration against current evidence before accepting it. Retrieval finds the right finding; discipline prevents premature acceptance of one that's only partly right. They are not competing fixes — they address different failures.

These are cheap, context-level interventions, not model upgrades. The details, evidence, and replicated results are in those posts.

**Mapped but not built: environment grounding.** A standing system model — the kind of causal graph tools like Traversal invest in — gives the agent structural context before the first query: what depends on what, what changed, what's within blast radius. That's valuable, but it carries a staleness hazard. A topology snapshot that's two deploys stale is worse than no topology at all — the agent trusts the model and misses the change that caused the incident. Building reliable, automatically-updating environment grounding is its own investigation, one this series scoped out rather than hand-waved through.

## The throughline

This series proved a specific causal chain. Memory alone helps exact repeats but breaks on partial matches. Better retrieval helps drift but can't separate a partial match from a true one — they score identically. The lever that gets past that wall is a reasoning discipline that forces the agent to corroborate what it recalls against what it observes.

In short: the agent is only as strong as the reality you construct for it, and the discipline with which it reasons about that reality. You can't solve a grounding problem with a better model, or a trust problem with better embeddings. The changes that matter live in the context — what you feed the agent, and how you instruct it to reason.

That's context engineering. It's the actual work of building AI SRE tools — more than model selection, more than harness plumbing. [Post 10](10-memory-for-the-sre-loop.md) and [Post 11](11-similarity-search-and-validation-discipline.md) are the proofs. The reference implementations are in the repo.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
