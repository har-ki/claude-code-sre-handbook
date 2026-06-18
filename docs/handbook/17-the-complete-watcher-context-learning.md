# The Complete Watcher: Context + Learning

*One watcher that investigates, proposes fixes, and learns from what actually ships.*

This post combines context engineering from Part 3 and the learning loop from Part 4 into one watcher. It investigates problems, suggests fixes, and learns from merged fixes. But it can still learn the wrong lesson if someone merges a bad solution.

Here, two important parts come together. There is not much new to build — the focus is on making sure everything fits and works well together.

## What is the complete watcher?

Until now, everything was separate. [Part 3](14-the-complete-watcher.md) built a watcher that used context — runbooks, correlation, memory, and discipline — to make decisions. [Part 4](16-the-merge-is-the-signal.md) built a learning loop that learns from what gets merged. Now this post brings them together: one watcher in [`watcher-complete/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-complete) that does both.

The watcher now follows the same steps as before, but with a new third phase:

1. **Detect** — Check ClickHouse for errors, identify the problem, and make sure it's not already being fixed.
2. **Investigate (Phase 1)** — Use the runbook to look into the error, trace it to the cause, recall any past findings, and double-check them.
3. **Propose (Phase 2)** — Suggest a fix, open a draft PR, and save the finding to memory.
4. **Learn (Phase 3)** — When the PR is merged, compare the original finding to what was actually shipped, and write down what was learned.

A human still decides what gets merged. The watcher can suggest and learn, but it can't approve its own PR. That decision — and the learning — still depends on a person.

## Keeping memory and audit separate

Two key things from Part 3 had to work with the new learning loop, and they did. These are often where this kind of system fails.

First, the two stores stay separate. [Part 3](13-memory.md) kept the agent's memory (`memory-store/`, where the agent reads and writes) apart from the audit trail (`incident-store/`, which is append-only for people and compliance). The learning loop adds outcomes and lessons to the agent's store. It would have been easy to mix these up, but they remain separate. The agent learns from its own store; the audit trail is for others to review what happened. Different uses, different trust, different stores.

Second, recall provides more information, but discipline remains key. In Part 3, recall returned a past finding, but discipline made the agent check it against what is happening now rather than just trust it. Now, recall gives the finding, the outcome, and the lesson. But the rule remains: a lesson is a hypothesis to test, not a fact to trust. This matters — a lot. The failure-mode section explains why.

## Putting the watcher to the test

A full test on `kind-claude-sre-demo` showed the watcher working step by step. First, it found a `StockMismatchError` on `ecommerce-api` (fingerprint `e2836e74`). Recall found a previous finding, but no lesson had been learned yet. Next, in Phase 1, the watcher traced the error from `inventory.js:59` back to a non-atomic decrement at line 55 and a race window at line 53. Then, in Phase 2, it suggested using an in-process mutex and opened a draft PR.

A reviewer keeps the PR but rewrites the fix. Since an in-process mutex won't work across replicas, they switch to a database-level `SELECT FOR UPDATE` and merge the change. Then, in Phase 3, the watcher compares its suggested fix (the mutex) to the merged solution (row-locking) and records the lesson: the real problem was concurrency across instances, not just threads. When the same fingerprint is triggered again, Phase 1 starts with this lesson — "the in-process mutex wasn't enough; check for multi-instance concurrency" — instead of starting from scratch.

This matches what [Post 16](16-the-merge-is-the-signal.md) showed, but now it runs inside the fully integrated watcher.

## When the merge teaches the wrong thing

Here is the most important result — and it is not perfect.

A merge is an outside signal, so it seems more trustworthy than the model's self-grading. But outside does not mean correct. A merge means only that a human approved the change. It does not mean the change is actually right. The system cannot tell if the merge was careful or careless — both look the same.

To demonstrate this, I intentionally caused a failure. The watcher investigates and suggests a fix. Then a reviewer quickly approves a bad fix — a `try/catch` that hides the `StockMismatchError` so it no longer appears, without solving the real problem. The symptom goes away, and the PR is merged. In Phase 3, the watcher does what it is supposed to: it compares the original finding to the merged change and writes a confident lesson — "the fix was error handling, not a race condition." But this lesson is wrong, and now it is stored as correct.

When the same fingerprint happens again, recall brings up the bad lesson right next to the still-correct original finding — a clear contradiction in the agent's context. What happens next is the real test.

**What we learned: discipline can catch the mistake, but not always.** The rule says the agent should check the recalled lesson against what is really happening. Since the code still has the race, an agent that reads the code can find the bug the lesson told it to ignore. That is discipline working — the same process that worked in [Part 3](14-the-complete-watcher.md) (4 out of 4 times with discipline, 1 out of 4 without). But a lesson that comes with a merge's authority is a stronger anchor than just a recalled finding. The agent can trust it too much. Nothing forces the agent to double-check.

This is the "merge-grounding wall." It is like Part 3's "retrieval wall." There, retrieval could not tell a real incident from a partial match — both looked the same, and discipline was the only fix. Here, a merge cannot tell a careful review from a careless one, and discipline is the only defense. Both cases show the same lesson: signals are not the truth, and the only real safeguard is for the agent to check against reality every time.

Learning from merges is better than self-grading. Self-grading drifts with nothing to keep it honest; at least merges depend on a human decision. But the watcher still learns whatever quality of merges it gets. If merges are careless, it learns careless lessons. The watcher can follow the merge, but it cannot make merges correct.

## The core lesson

[Part 3](09-the-context-problem.md) asked what guides the agent's reasoning and found the answer: context you design on purpose, with discipline, so that memory helps but does not mislead. [Part 4](15-remembering-isnt-learning.md) asked if the agent can improve over time, and answered: yes, as long as it learns from a real signal it cannot fake — like a merge, already part of the workflow. The complete watcher does both.

The true goal is not a perfect watcher. It is one that uses strong context, learns from real outcomes, and is disciplined enough to question its own memory — because both context and merges are just signals, and signals can be wrong. When those signals fail, only discipline keeps the agent on track. That is the heart of the series.

---

*The complete watcher — context engineering plus the learning loop — is in [`watcher-complete/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-complete). The Part 3 context-only watcher stays at [`watcher-capstone/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-capstone) as the reference for a watcher that remembers but doesn't learn.*

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
