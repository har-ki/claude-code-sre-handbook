# Remembering Isn't Learning

The watcher we finished Part 3 with has a good memory. Before it investigates an incident, it reads what it found the last time it saw that incident. After it proposes a fix, it writes down what it learned. The memory loop closes, and the discipline keeps it honest — a recalled finding is a hypothesis to confirm, never an answer to trust.

That watcher remembers. It does not learn. Those are different things, and the gap between them is the whole of Part 4.

## What the Watcher Can't Do

Here is what the watcher cannot do: it sees a `StockMismatchError` on `ecommerce-api`, investigates, and writes a finding: the stock decrement in `inventory.js` isn't atomic; two orders race, and one wins. It opens a draft PR. A human looks at it.

Then one of two things happens. The human merges the fix — maybe as-is, maybe after rewriting half of it. Or the human closes the PR without merging, because the diagnosis was wrong.

The watcher never finds out which. Next time `StockMismatchError` fires, it pulls up the same finding and hands the agent the same starting point — with no idea whether that finding led to a fix that shipped or was thrown away. A finding that was right and a finding that was wrong are stored identically. The agent reads both with the same confidence.

That's the difference between a notebook and a teacher. The watcher has a notebook. It records what it thought. It has no way to grade its thinking against what actually happened, so it can't get better — it can only accumulate. Remembering is recording the past. Learning is letting the past change what you do next.

## The obvious fix is the trap

The obvious fix: have the agent grade itself. After the fix is in, ask the model — did your diagnosis hold up? Was the fix good? Write the verdict into memory and weight future recall by it.

This is exactly the thing not to do, and there's a clean body of work on why.

The case for an agent learning from its own history is Reflexion (Shinn et al., NeurIPS 2023). An agent attempts a task, fails, writes itself a plain-language note about what went wrong, and tries again with that note in context. It works — the agent improves across attempts without anyone retraining the model. It's the blueprint for the loop we want.

But read why it works. In Reflexion, the agent doesn't decide for itself whether it failed. An external evaluator does — unit tests pass, or they don't; the game is won or lost. The agent writes the lesson, but something outside the agent rules on whether there was a failure to learn from. The reflection is the agent's; the verdict is the world's.

Take that external verdict away, and the result flips. Huang et al. (ICLR 2024) tested whether models can correct their own reasoning with no outside signal — just the model rereading its answer and judging it. Performance got worse. The model talks itself out of right answers as readily as wrong ones, because it has no ground truth to check against — only its own confidence, which is exactly the thing that's unreliable. They also found that several earlier "self-correction works" results had quietly leaned on the answer key to decide when to stop. Remove the key and the effect went with it.

Put the two papers together, and they aren't in conflict. They draw the same line from opposite sides:

> A self-improvement loop is only as good as the grounding of its feedback signal. An external signal — something the agent can't author — drives real improvement. An internal signal, the model grading its own work, drives drift.

When a model checks its own work, it's just marking its own homework. It keeps agreeing with itself, so its memory doesn't get better — it just gets more certain about whatever it thought first. That's not learning. That's a system stuck in a loop, treating its first answer as fact and slowly getting worse over time.

So the self-grading fix is off the table — not because it's hard, but because the literature says it makes the watcher worse, even though it looks like it makes them better. The dangerous failures are the ones that look like progress.

## What this part has to find

That rules out the easy answer and names the real problem. The watcher needs a feedback signal from outside that says whether this finding led somewhere good or not — and it needs to get that signal without inventing a new chore for the on-call engineer who's already had a long night.

There's already a signal like that in the workflow, and nobody has to do anything new to produce it. That's the next post.

Right now, the watcher we built in Part 3 is as good as a system that only remembers can get. To help it learn, we need to give it feedback it can't create or influence itself. Everything in Part 4 is about solving that challenge.

---

*The shipped watcher is in [`watcher-capstone/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-capstone) — the system this post diagnoses. It remains the reference for a watcher who remembers; Part 4 builds the one who learns.*

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
