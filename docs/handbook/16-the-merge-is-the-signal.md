# The Merge Is the Signal

*For the watcher to truly learn, it needs real feedback. This feedback already exists — it's the merge.*

When a person merges, accepts, or rewrites the watcher's draft PR, it's an outside verdict on whether the suggestion was good. A third Claude Code phase runs at merge, comparing the original suggestion to what actually shipped, and writes down the lesson. On-call engineers don't have to do anything extra — the feedback comes from what they already do.

[Earlier](15-remembering-isnt-learning.md), we saw that if the watcher grades its own work, it quickly drifts off course. This post shows how to fix that by using an outside signal for feedback, building the loop around it, and proving that a merge changes how future investigations begin.

## Why the merge

Go back to the principle from [last post](15-remembering-isnt-learning.md): a self-improvement loop is only as good as the grounding of its feedback signal. The model can't be the judge of its own diagnosis — that's the failure mode the literature warns about. So the signal has to come from outside the agent.

The merge is that signal, and it has four properties that make it almost too good to pass up:

- **External.** A human decides, not the model. The agent can't author the verdict on its own work.
- **Binary.** Merged or not. Closed or not. No fuzzy self-assessment to game.
- **Privileged.** Merging is an action a reviewer takes deliberately, with their name on it. It carries weight that a comment or a thumbs-up doesn't.
- **Free.** It already happens. Every fix that ships gets merged; every bad diagnosis gets closed. The signal is a byproduct of work the team does anyway.

This is the key idea: The real work happens during review, when a human reads the draft PR and decides to accept, change, or reject it. The merge event gives us real feedback and starts the learning process. We don't ask people to rate the watcher — we just look at what they do with its output.

## What gets built

Three pieces, all in a new [`watcher-learning/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-learning) directory. This is the learning mechanism in isolation — not the full watcher. That's the next post.

### The store now tracks what happens next

Previously, the store just kept findings and their details, allowing us to look up similar past cases. Now, each finding also gets three new fields:

- **`outcome`**: `pending`, `merged`, `merged_modified`, or `closed_unmerged`
- **`verdict`**: a short note on what the merge showed
- **`lesson`**: a clear takeaway written after learning

A finding starts as `pending`, and most stay that way because merges often happen much later, or not at all. That's normal — the store still works fine with many pending findings. When an outcome finally appears, `recall()` includes it. Now, when you look up a past case, you see not just "what we found," but also "how it turned out" and "what we learned."

This change to the data structure is the backbone of the update. The rest is just making sure these fields are filled with reliable information.

### A third phase that learns

The watcher used to have two steps: investigate, then suggest a fix. Now there's a third step that runs when the code is merged. This new step is simple — it uses just two things:

- The original finding from the store
- The final merged code changes (the diff)

This is on purpose. The learning step only looks at the diff, because it's always there. It doesn't read commit messages or review comments, and it doesn't care how the bug was fixed — just what actually shipped. The diff is the truth, and only the truth should teach the system. Anything else is extra and not required.

Here's what the learning step does:

- If the merged diff is empty, the fix was accepted as-is. That means the diagnosis was correct. Set `outcome=merged` and note that no changes were needed.
- If the merged diff isn't empty, the fix was changed before merging. Set `outcome=merged_modified`. The lesson explains what was different and why it matters. This teaches the most: the suggestion was close, but needed improvement.
- If the pull request was closed without merging, the suggestion was rejected. Set `outcome=closed_unmerged`. This is a weaker negative signal, since PRs can be closed for many reasons. But it still gives some feedback.

This learning step only reads the diff and writes down what was learned — nothing more. It never tries to push changes past a human. It just learns from what actually got through the review.

### The trigger

The main method is a GitHub Action that runs when a pull request closes. It checks if the PR was merged, finds the fingerprint from the branch name, and starts the learning step. This all happens on GitHub, with no need for extra polling.

For offline or local setups, there's a simple script that checks the PR status using `gh pr view`. When the PR finishes, it runs the same learning step. Both ways feed into the same process, so the system works the same no matter how the merge is detected.

No webhooks needed. Watching merges is simple — the GitHub Action handles online cases, the script covers the rest. Setting up a webhook server is overkill for this job.

## Proof: a merge changing a later investigation

A diagram isn't enough — this post has to prove that merging really changes what happens next. Here's how it plays out:

First, trigger the usual incident: `StockMismatchError` in `ecommerce-api`, fingerprint `e2836e74`. The watcher finds the non-atomic decrement in `inventory.js` and suggests using an in-process mutex around the code. It opens a draft PR. The finding enters the store as `outcome=pending`, with no verdict or lesson yet.

Next, a reviewer steps in. They keep the PR but realize an in-process mutex won't work across multiple API servers. Instead, they rewrite the fix to use a database-level `SELECT FOR UPDATE`. They merge the change. The GitHub Action runs. The learning step compares the original mutex suggestion to the merged row-lock, then writes:

`outcome=merged_modified`. Verdict: the diagnosis was correct (there was a non-atomic decrement), but the fix needed improvement — an in-process mutex was swapped for a database-level lock. Lesson: the real issue spanned multiple instances, not just threads; a single-process lock isn't enough for multi-replica systems.

Now, trigger the same fingerprint again. This time, the system's `recall()` brings back the earlier finding along with its lesson. Before, it would just show `outcome=pending` and no lesson. After the merge and learning, the new investigation starts from "the in-process mutex wasn't enough — check for concurrency across instances," not from scratch. The merge has changed the starting point for future investigations.

This is the proof: the same incident, checked twice, and the merge in between changes what happens the second time. The other two cases also ran: a merged-as-is confirmation (`merged`), and a rejected suggestion (`closed_unmerged`), so all possible outcomes are covered in practice, not just in theory.

## Where this sits, honestly

There are three real limits to this approach:

**Slow.** Learning is slow because merges take days. The loop only learns as fast as people review and merge code. This isn't a flaw — it's intentional. Fast feedback usually means the system is grading itself, which leads to mistakes. Waiting for real feedback from others is slower but much more reliable.

**Sparse.** Only merged or closed pull requests teach the system. Everything else stays "pending" — findings that go nowhere, incidents that fix themselves, PRs left open. Most findings never get a final outcome. The store has to work even when it's mostly empty. The learning signal is naturally thin, since only a few incidents ever reach a verdict.

**Merge isn't proof.** A merge just means a human approved the fix, not that it was actually correct. Careful reviews and quick approvals both count as merges, and the system can't tell the difference. Getting a human sign-off is still better than letting the model judge itself, but it isn't perfect. Sometimes the wrong lesson gets learned if a merge was careless. That's a risk the next part will address.

## Where this sits in the arc

[Part 3](14-the-complete-watcher.md) gave the watcher its context — what it reasons against. This post gives it a way to update that context from outcomes it can't fake. Post 17 puts both together into a single production-shaped watcher and confronts the last problem head-on: what happens when the merge teaches the loop the wrong thing.

---

*The learning loop, store schema, triggers, and experiment artifacts are in [`watcher-learning/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-learning). The three-outcome run is under [`experiments/16-downstream/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-learning/experiments/16-downstream).*

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
