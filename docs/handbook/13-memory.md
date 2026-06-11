# Memory for the SRE Loop

*The hard part of agent memory isn't storing the past. It's stopping the agent from trusting it too much.*

## Why this post

The watcher from [Post 5](05-building-the-always-on-watcher.md) takes an alert to a draft PR in five minutes. But it has no memory. The same bug fires on the same service, and the agent works it out from scratch every single time — even though it solved the identical problem last week.

So the obvious move is to give it memory: save what you learned, load it next time. That part is easy. This post does it in fifty lines.

The catch is what happens when memory is *almost* right. A past finding that's relevant but incomplete is more dangerous than no memory at all, because it arrives sounding like an answer and the agent stops looking. That's the real problem, and better storage doesn't fix it.

**The takeaway, up front:** memory is worth adding, but recall is the easy half. The hard half is teaching the agent to treat what it remembers as a lead to check, not a conclusion to accept. Get that wrong and memory makes the agent worse — and keeps doing so, because it writes its mistakes back for next time.

## Three things memory has to get right

Adding memory to an agent is really three decisions, not one:

1. **What to save and load.** What goes into the agent's working context before it starts thinking.
2. **How to find the right past finding.** When the incident doesn't look exactly like last time, can you still surface the relevant note?
3. **How the agent should treat what it finds.** Does it accept the recalled note and stop, or check it against what's actually happening now?

Most of the effort goes to the first two — building the store, making search smarter. This post will show that the third one is where memory actually succeeds or fails. The first two are plumbing. The third is the engineering.

We'll build memory two ways — plain files, then similarity search — not because you need both, but because the second one is what most people reach for to fix the first, and it's worth seeing exactly how far it gets you (and where it stops).

**Setup:** Claude Sonnet 4.6 · the memory findings here are measured on frontier; local replication on Qwen3.6 is future work, not yet run. The discipline is a prompt convention and is expected to port, but this post claims only what was measured.

## Memory is just files

Claude Code has no "memory feature." There's no special command. What it has is the ability to read and write files — the same ability it uses for source code. So memory is a directory:

```
memory-store/
└── incidents/
    └── e2836e74.md      # what we learned last time this fired
```

The watcher already gives each incident a short fingerprint — a hash of the service name and error type. The inventory race condition fingerprints to `e2836e74`. We reuse that as the filename. Each file is plain markdown: what the root cause was, what the fix was, when it was resolved.

Two steps wire it in:

- **Before investigating,** the agent reads the file for this fingerprint. If it exists, it's a head start. If not, fresh investigation.
- **After fixing,** the agent writes back what it learned.

That's the whole system. One thing about that second step is worth knowing now, because it surprised me: **the agent reliably reads memory on its own, but it does not reliably write it.** Left to its own judgment, it fixes the bug and moves on without recording anything. The write has to be a explicit, required instruction in the prompt — "save this, this step is mandatory" — or your memory store stays empty. Reading is free; writing needs a push.

(One housekeeping note: keep two separate stores. `memory-store/` is what the agent *learned* and is allowed to reuse. A separate `incident-store/` holds the human-readable incident reports and an audit log — what *happened*, for people and compliance, written by the system, not the agent. Don't mix the agent's working memory with your audit trail. This post is about the first one.)

## Where plain files break

File memory works perfectly when the incident is an exact repeat. It breaks in two ways the moment reality drifts.

**The name changes but the bug doesn't.** Someone renames the error class in a refactor. New name, new fingerprint, no file found — even though the fix is sitting right there under the old name. Memory misses.

**The name stays but the bug is different.** The same error fires, the file loads, but *this* time there's a second cause the old note never mentioned. Memory loads a half-right answer and points the agent at an incomplete fix.

The first problem — missing a relevant note because the surface changed — is a search problem. And search problems have a standard fix.

## Smarter search: similarity

Instead of matching the exact fingerprint, match on *meaning*. Convert each past finding into a list of numbers (an embedding) that captures what it's about, and when a new incident comes in, find the stored finding whose numbers are closest. "Stock went negative" and "inventory corrupted under load" come out close even though they share no exact words.

The whole thing is a local embedding model and a similarity score — no vector database, no new infrastructure. For a store of a few hundred findings, a plain loop comparing numbers is plenty fast:

```python
def cosine_similarity(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    return dot / (norm_a * norm_b) if norm_a and norm_b else 0.0
```

And it **works** for the first problem. When the error gets renamed, exact matching misses completely, but similarity still finds the right note — scoring it a strong 0.81. That's a real win. Search got smarter, and the renamed-bug case is solved.

So if better search fixes the first break, surely it fixes the second one too?

It does not. And this is the heart of the post.

## The wall: search can't tell safe from dangerous

Here's what the similarity scores actually look like across four incidents:

| Incident | What it is | Score |
|---|---|---|
| Same bug, renamed | should match | 0.81 |
| Unrelated incident | should not match | 0.74 |
| **The real repeat** | **safe to reuse** | **0.798** |
| **The half-right repeat** | **dangerous to reuse** | **0.798** |

Look at the last two rows. The genuinely-identical incident and the one that's only *partly* the same score **exactly the same: 0.798.** There is no cutoff that keeps one and drops the other — they're the same number.

Why? Because on every feature the search can see — same service, same error, same shape — the two incidents *are* identical. The thing that makes one dangerous (a second, hidden cause this time) isn't visible to the search at all. No better embedding model changes this. You cannot search your way out of it.

This is the lesson that matters: **better retrieval solved the search problem and did nothing for the trust problem.** The agent is about to be handed a note that's only half-right, with a confidence score identical to a note that's perfectly right. Storage and search have done all they can. The fix has to live somewhere else.

## The fix: make the agent check, not trust

The somewhere-else is the prompt. One instruction: before using a recalled finding, the agent must state whether it actually matches what's happening right now, and keep investigating to confirm it.

```markdown
Before using the prior finding, classify it against current evidence:
- VALIDATED — it matches, because <reason>
- INVALIDATED — it doesn't match, because <reason>
Then corroborate with fresh evidence either way.
```

I ran the half-right incident four times with this rule on, four times with it off. The incident had two causes — the familiar race condition, plus a caching bug the old note never mentioned. Catching it meant finding *both*.

| | Caught both causes |
|---|---|
| Without the rule | 1 of 4 |
| With the rule | 4 of 4 |

Small numbers, clear direction. One run caught it without the rule, so the agent *can* do this on its own — it just usually doesn't bother once a plausible answer is in front of it. The rule makes it reliable.

The mechanism is the surprising part. **Three of the four "with the rule" runs said the old finding VALIDATED — it matched — and then found the second cause anyway.** The rule didn't work by making the agent distrust memory. The memory was right, as far as it went. It worked by forcing the agent to *look closely enough to confirm it*, and looking closely is what surfaced the part the old note left out.

That's the whole trick. The danger of a half-right memory isn't that it's wrong. It's that it's right enough to end the investigation early. Forcing the agent to check doesn't make it doubt the memory — it makes it finish the job.

## It cleans up after itself, too

One more reason this matters. After each incident, the agent writes its finding back to memory for next time.

The runs that anchored on the half-right answer wrote *that* back — overwriting the good note with the incomplete one. The next incident then loads an even worse starting point. Bad memory compounds.

The runs that checked their work wrote the complete finding back. The check doesn't just fix today's incident — it keeps the memory store honest for the next one. That's why this is the capstone of the series: memory touches all three decisions at once, and the discipline that makes recall safe is the same discipline that keeps the store from rotting.

## What to take away

If you're adding memory to an agent, remember three things:

1. **Reading is free; writing needs a push.** Make saving an explicit, required step or your store stays empty.
2. **Better search fixes finding, not trusting.** A half-right memory scores just as high as a perfect one — no amount of retrieval tuning separates them.
3. **The real fix is one instruction:** make the agent check a recalled finding against what's happening now. It works by forcing a proper look, not by breeding distrust — and it keeps your memory clean for next time.

The store is fifty lines. The search is fifty more. The instruction that makes the whole thing safe to use is a single paragraph in a prompt. Most of the work in agent memory isn't the memory — it's earning the right to trust it.

---

Both versions — plain files and similarity search — are in the repo at [`watcher-memory-example/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-memory-example) and [`watcher-semantic-example/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-semantic-example). Clone it, run the half-right incident with the rule on and off, and watch where the agent stops. The final post wires all of this into a watcher you can deploy.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
