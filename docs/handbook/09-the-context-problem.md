# 09 — The Context Problem

*Context engineering for AI SRE: how to construct what the agent reasons against.*

You've said context matters most—and you're right. Part 3 shows how to build it: what to include, what to leave out, what happens when the window fills up, and how to keep the agent from trusting the wrong information. Five posts, five examples, one laptop, one clear result.

Here's where things broke. The model worked well, and the harness was solid—Parts 1 and 2 proved it. But when I gave the agent a memory of past incidents, a new problem arose. The agent remembered a similar case and stopped searching, even though that memory was only partly correct. For example, it spotted a familiar StockMismatchError, but missed a second bug—a stale cache—because it thought it already had the answer. The fix wasn't wrong, just incomplete. In production, that's still a failure.

This wasn't a model or harness problem. The agent made good decisions—but based on the wrong information, shaped by its memory. Context engineering builds the world the agent sees, and it's the key to everything an SRE agent does. A fancy model with bad context loses to a simple model with good context. Part 8 proved this: the local model solved the same incidents as the advanced one when it had the right context. The memory failure above shows the flip side—give a smart agent slightly wrong context, and it fails just as smartly.

Everyone agrees: context is the real challenge. The pitch is simple—the agent's value isn't running kubectl; it's finding the context a human on-call would spend 25 minutes gathering. They're right about the problem. But few talk about how context is built, since that's often the secret sauce. This series shows the process, using Claude Code as shipped and hardware you already have—including where things break.

## Construction is three decisions, not one

It's easy to answer 'How do I build context?' with a list—telemetry, topology, code, runbooks, past incidents—and call that the recipe. The list is real (see below), but ingredients aren't the method. Context is built through three key decisions, each with its own risk: first, what goes in; second, how you manage it as it grows; third, how you make the agent use it.

1. **What goes in.** Which facts about the system, the failure, and the history earn a place in a finite window — and which you deliberately leave out.
2. **How you manage it as it grows.** What you do when a forty-minute session fills the window: what gets correlated, summarized, evicted, or fetched on demand.
3. **How you make the agent reason over it.** What discipline prevents the model from trusting a recalled finding that's only half-right?

**A note on models.** Part 3 runs across two models — Claude Sonnet 4.6 on the frontier, and Qwen3.6 locally via Ollama — but not as alternating arcs the way Parts 1 and 2 were. Here the model is a condition of the experiment, not the subject of it. Each post picks whichever model makes its context decision *visible* and says which and why up front. Some findings only appear on a small local window; others are measured on frontier with local replication still ahead. Every post opens with a one-line Setup so you always know what you're looking at and why — the model varies, but the incident, the phases, and the discipline stay fixed throughout.

Most writing on agentic SRE treats these as one problem: 'give the agent good context.' But they're three separate engineering challenges. You can get the inputs right and still fail on management—maybe you summarized away the log line that mattered. You can manage the window perfectly and still fail on discipline—the agent trusted an incomplete memory and stopped searching, just like the failure above. Each post in Part 3 tackles one decision and shows how to fix its failure mode.

## Decision 1 — What goes in

The raw material you assemble before and during an incident: first, a model of the environment (cluster state, manifests, resource limits); second, the evidence to investigate with (logs, traces, metrics); third, the source of the failing service; fourth, procedural knowledge; and fifth, recall of past incidents.

Two pieces here deserve a flag now. Runbooks are among the strongest levers in the field — a phase-structured procedure prevents the agent from exploring at random and makes its investigation repeatable. The Skill files from Part 1 were already doing this; Part 3 names it and shows how to write one that constrains without straitjacketing. And service topology — the dependency graph every vendor leads with — is the one thing a single-service demo can't honestly prove. I'll show where it belongs and scope it out rather than fake a dependency graph that isn't there.

## Decision 2 — How you manage it as it grows

Inputs are static; a session is not. Tool outputs pile up — kubectl dumps, query results, file reads — and the window fills. That leaves two places to engineer, and two places to fail: correlation and compaction.

Correlation is the missing piece everyone needs but few build. Gathering logs, traces, and metrics is just collection; connecting a deploy to an error spike to a code change is correlation—and that's what finds the real cause. An agent with all the data but no correlation has all the evidence and still can't tell the story.

Compaction is what the harness does when the window fills up—it summarizes old tool output to make space. Claude Code surprised me here: it didn't compact when I expected, because it measured against the wrong baseline.

## Decision 3 — How you make the agent reason over it

Same context, same model, but different discipline means different results. The sharp case is what I opened with: the agent recalls a past incident that's partly right—a partial match—and anchors on it, stopping the search. Better retrieval doesn't fix this; I'll show that similarity scores for safe and risky cases are identical, so retrieval can't tell them apart. The fix is forced corroboration: making the agent check a recalled idea against fresh evidence before acting. It's easy to add and makes the difference between helpful memory and harmful memory.

## What you'll have built by the end

The posts follow the three decisions in the order you actually build them — get the right things in, manage them as the window fills, impose discipline on the reasoning — and then the one ingredient that needs all three at once.

**Decision 1 — what goes in:**

* [Post 10](10-runbook-as-context.md) — Runbooks as context. Does structured procedural context constrain the agent's exploration and improve the catch? The Skill files from Part 1, measured as a context lever.
* [Post 11](11-correlation.md) — Collection isn't correlation. An agent with every signal that still can't assemble the story — and the construction that links a deploy to an error to a code change.

**Decision 2 — how you manage it as it grows:**

* [Post 12](12-the-window-edge.md) — The window edge. What Claude Code actually does when context fills, with token traces. Why it didn't compact when I expected it to, and how to fix the baseline.

**Decision 3 — how you make it reason, on the ingredient that needs all three:**

* [Post 13](13-memory.md) — Memory for the SRE loop. Memory is the thread that runs through every decision: you retrieve a past incident (what goes in), you write findings back without poisoning the store (how you manage it), and you have the agent corroborate a recalled finding rather than anchoring on it (how it reasons). Get any one wrong, and the whole thing breaks. This is where the three decisions stop being independent — forced corroboration against partial-match recall.
* [Post 14](14-the-complete-watcher.md) — The complete watcher. Everything from Part 3, assembled into one watcher you can clone and run on your own cluster.

By the end, you'll have a practical method for building context for an SRE agent—not a product to buy, but a practice to use—and a clear map of where things still break. That's the point: the failures are the findings, and each one makes the payoff sharper.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
