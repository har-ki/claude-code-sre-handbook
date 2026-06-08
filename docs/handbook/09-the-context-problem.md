# 09 — The Context Problem

*Context engineering for AI SRE: how to construct what the agent reasons against.*

You've told me context is what matters most. You're right. Part 3 shows how to build it: what goes in the window, what you leave out, what happens when it fills up, and how you stop the agent trusting the wrong thing. Five posts, five pieces of evidence, one laptop, one clear payoff.

This is the failure that kicked things off. The model was competent; the harness worked—Parts 1 and 2 proved it. But giving the agent memory of past incidents surfaced a new problem. It recalled a similar situation, anchored to that memory, and stopped investigating—even though the recalled issue was real but incomplete. The classic case: the agent identified a familiar StockMismatchError race, but this time, a second bug—a stale cache—went unnoticed because memory made it think the answer was solved. The fix wasn't wrong. It was incomplete—which, in production, is failure all the same.

This isn't a failure of the model or the harness. The agent reasoned correctly—but against the wrong reality, narrowed by its own memory. Context engineering builds the reality the agent reasons against, and it's the binding constraint on everything an SRE agent does. A leading-edge model with bad context loses to a smaller model with good context. Part 8 already showed this: the local model resolved the same incidents as the advanced one when given the same context. The memory failure above proves the inverse—give a competent agent subtly wrong context, and it will fail competently.

Everyone in this space agrees: context is the challenge. The pitch is always the same—the agent's value isn't running kubectl; it's assembling the context a human on-call would spend 25 minutes gathering. They're right about the problem. But the details of construction are rarely discussed, since they're often central to the product itself. This series opens that process up, using Claude Code as shipped, on hardware you already have—including the places where it breaks.

## Construction is three decisions, not one

It's tempting to answer "how do I build context" with a list of ingredients — telemetry, topology, code, runbooks, past incidents — and call that the recipe. The list is real (it's below), but ingredients aren't a method. Context gets constructed through three decisions, made in sequence and at different moments, each with its own failure mode: first, what goes in; second, how you manage it as it grows; third, how you make the agent reason over it.

1. **What goes in.** Which facts about the system, the failure, and the history earn a place in a finite window — and which you deliberately leave out.
2. **How you manage it as it grows.** What you do when a forty-minute session fills the window: what gets correlated, summarized, evicted, or fetched on demand.
3. **How you make the agent reason over it.** What discipline prevents the model from trusting a recalled finding that's only half-right?

Most writing on agentic SRE collapses these into "give the agent good context." They're three different engineering problems. You can nail the inputs and still fail on management — you summarized away the one log line that mattered. You can manage the window perfectly and still fail on discipline — the agent trusted a memory that was relevant but incomplete and stopped looking, exactly the failure above. Each post in Part 3 takes one decision and shows the construction, so each one pays off its own failure mode.

## Decision 1 — What goes in

The raw material you assemble before and during an incident: first, a model of the environment (cluster state, manifests, resource limits); second, the evidence to investigate with (logs, traces, metrics); third, the source of the failing service; fourth, procedural knowledge; and fifth, recall of past incidents.

Two pieces here deserve a flag now. Runbooks are among the strongest levers in the field — a phase-structured procedure prevents the agent from exploring at random and makes its investigation repeatable. The Skill files from Part 1 were already doing this; Part 3 names it and shows how to write one that constrains without straitjacketing. And service topology — the dependency graph every vendor leads with — is the one thing a single-service demo can't honestly prove. I'll show where it belongs and scope it out rather than fake a dependency graph that isn't there.

## Decision 2 — How you manage it as it grows

Inputs are static; a session is not. Tool outputs pile up — kubectl dumps, query results, file reads — and the window fills. That leaves three places to engineer, and three places to fail: correlation, compaction, and selective injection.

Correlation is the missing piece everyone needs but few build. Pulling logs, traces, and metrics is just collection; linking a deploy to an error spike to a code change is correlation—that's what actually localizes a root cause. An agent with every signal but no correlation has all the evidence and still can't assemble the story.

Compaction is what the harness does at the window's edge—summarizing old tool output to free up space. The default threshold didn't fire when I expected, because it measures against a tokenizer baseline that didn't match my actual window: a 28K skill was already eating most of a 32K context. Post 12 shows the tuning that fixes it and what compaction does once the baseline is right.

Selective injection is putting only what's needed in front of the model at each step, rather than everything at once. It's where the MCP-versus-CLI token cost lives, which determines how much window is left for actual reasoning after the plumbing takes its cut.

## Decision 3 — How you make the agent reason over it

The same context, the same model, different discipline, different outcome. The sharp case is the one this post opened on: when the agent recalls a past incident that's genuinely relevant but incomplete — a partial match — it anchors on the recalled finding and stops looking. Better retrieval doesn't fix this; I'll show that the similarity scores for the safe and dangerous cases are identical, so retrieval can't distinguish between them. What fixes it is forced corroboration: a discipline that makes the agent verify a recalled hypothesis against fresh evidence before acting. It's cheap to add, and it's the line between memory that helps and memory that poisons.

## What you'll have built by the end

The five posts follow the three decisions in the order you actually build them — get the right things in, manage them as the window fills, impose discipline on the reasoning — and then the one ingredient that needs all three at once.

**Decision 1 — what goes in:**

* [Post 10] — Runbooks as context. Does structured procedural context constrain the agent's exploration and improve the catch? The Skill files from Part 1, measured as a context lever.
* [Post 11] — Collection isn't correlation. An agent with every signal that still can't assemble the story — and the construction that links a deploy to an error to a code change.

**Decision 2 — how you manage it as it grows:**

* [Post 12] — The window edge. What Claude Code actually does when context fills, with token traces. Why it didn't compact when I expected it to, and how to fix the baseline.
* [Post 13] — Only what's needed. Selective injection and the MCP-versus-CLI token cost: how much of your window the plumbing eats before the model reasons at all.

**Decision 3 — how you make it reason, on the ingredient that needs all three:**

* [Post 14] — Memory for the SRE loop. Memory is the thread that runs through every decision: you retrieve a past incident (what goes in), you write findings back without poisoning the store (how you manage it), and you have the agent corroborate a recalled finding rather than anchoring on it (how it reasons). Get any one wrong, and the whole thing breaks. This is where the three decisions stop being independent — forced corroboration against partial-match recall, frontier versus local.

By the end you'll have a worked method for constructing context for an SRE agent — not a platform to buy, a practice to run — and a clear map of where it still breaks. That last part is the point: the failures are the findings, and each one sharpens the payoff.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
