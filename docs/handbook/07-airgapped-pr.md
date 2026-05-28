# 07 — From Investigation to PR, Air-Gapped
*The same demo from Post 2 — air-gapped. What matched, what it cost, and what the skill needed first.*

The ecommerce service is throwing checkout errors. You point Claude Code at it and ask it to find out why. Back in Post 2, a frontier model ran this exact investigation — read the telemetry, found the bug, opened a pull request — with the investigation skill doing the heavy lifting.

This time the model runs on the laptop. Nothing leaves the machine.

It identified the same race condition, wrote a similar fix, and opened the PR—air-gapped, running locally. However, it took 34 minutes, required three skill adjustments, and fumbled two edits. This post details those differences, costs, and the adaptations needed.

## You've seen the scenario

The scenario matches Post 2: an ecommerce service on a local Kubernetes cluster, using OpenTelemetry for traces and logs in ClickHouse. Checkout fails intermittently due to a time-of-check-to-time-of-use race in the inventory code, causing concurrent orders to read the same stale stock count.

The harness is the same: a `CLAUDE.md` registering `clickhouse`, `k8s`, and `gh` skills; three prompts—investigate using ClickHouse telemetry, propose a fix, then open a PR.

The original harness worked on the frontier model but not on `qwen3.6` without modification. That difference is the real topic of this post.

## What the skill needed to run locally

Three changes stood between the skill that worked on the frontier and a skill the local model could actually use. None were about the bug. All were about getting `qwen3.6` to behave like an agent instead of a text generator.

### It read the skills but never called them

In the first run, the model never invoked the `Skill` tool. It read the skill descriptions in `CLAUDE.md`, noted that ClickHouse was relevant — and then reached for an unrelated MCP server that happened to be configured, trying to investigate Kubernetes errors through it. Zero skill calls the entire session.

The frontier model interpreted the instruction to "load the skills at the start of an investigation" as an actionable task. By contrast, `qwen3.6` treated it as informative prose rather than a command. The fix was to move from 'implying' to 'specifying': the `CLAUDE.md` now spells out the call procedure.

```
Load them at the start of any investigation by calling the Skill tool, e.g.
Skill(skill="k8s"), Skill(skill="clickhouse"), Skill(skill="gh").
```

After that, the first tool call of the next run was `Skill(skill="clickhouse")`. The lesson generalizes past this one model: a local model often needs the mechanics of an action written out, not just the intent. Frontier models infer the step; smaller ones execute what you name.

### It found the answer and kept going

With skill loading fixed, the next run found the root cause at query six but continued to run all 23 queries, mechanically following the ClickHouse skill's six-step method even after finding the answer. Memory and context bloated, and the run slowed.

The frontier model stopped when it had enough. The local model needed to be told that "enough" is a state it's allowed to reach. So the skill gained an Early Exit Rule, placed before the methodology rather than buried after it:

```
STOP investigating as soon as you identify a root cause. Skip to CONCLUDE.
Maximum 10 queries. Never re-run a query that already returned data.
```

Investigation dropped from twenty-three queries to ten.

### It didn't know when to stop fixing

The pattern repeated during editing: after finishing the investigation, the model performed unnecessary edits, exceeding 56K tokens. Two guardrails were added—a limit of 20 tool calls per prompt, and a clear separation between investigating and fixing.

None of these are model bugs. They're the difference between an agent that infers the shape of a task and one that needs the shape drawn. That difference is what "running locally" actually costs in configuration, and it's invisible until you try.

## The run that closed the loop

With the skill adapted, session `a1ef932a` ran the full three-prompt sequence to completion. Turn by turn:

**Investigation.** Loaded the `clickhouse` skill first, then found the root cause in six queries: checkout failures from stockouts, `Insufficient stock for product 7: requested 2, available 0`. It cross-referenced the inventory-reservation spans against the error timeline to confirm the correlation and reported a 50% error rate — 2,268 of 4,536 checkouts — with the queries as evidence. Ten tool calls, stopped on the Early Exit Rule. 4m22s.

**Root cause.** Read the source under `ecommerce/`, and correctly identified the TOCTOU race in `inventory.js`: a stock read, a simulated delay, then a decrement, with concurrent requests reading the same stale value. This is the same diagnosis the frontier model reached in Post 2 — arrived at independently, from the telemetry, by a model running on a laptop. 5m8s.

**Fix and PR.** The model implemented a per-product asynchronous lock to serialize the check-and-decrement step, which is the proper solution for a race condition. The tool then committed only the relevant file, pushed a new branch, and opened PR #7 using `gh` cli. The process was complete: an alert led to an open pull request, with no data leaving the machine.

The local run matched the frontier: same root cause, equivalent fix, PR opened. This reproducibility is the key takeaway, as supported by the repo evidence.

## The two stumbles, kept in

A sanitized demo would end there. This one had rough edges, and they're worth seeing, because they're what running a 35B model locally actually looks like.

The `Edit` tool failed twice. Both times it was whitespace — em-dash characters in the source the model didn't reproduce exactly — and both times it fell back to rewriting the whole file with `Write`. It got the right result, but not cleanly, and those retries cost real minutes at local prefill speeds.

Even with explicit prompts to use the `gh` skill, the model opened the PR using direct `git` and `gh` commands, bypassing the intended workflow. Skill invocation improved but remained unreliable.

Neither issue broke the run. Both are the kind of friction you expect when running a 35B model locally.

## What it cost

The whole session, end to end:

| Turn | Task | Duration | Tool calls | Input tokens |
|---|---|---|---|---|
| 1 | Investigation | 4m 22s | 10 | 25K → 31K |
| 2 | Root cause | 5m 8s | 5 | 31K → 35K |
| 3 | Fix + PR | 24m 50s | 16 | 35K → 47K |
| **Total** | | **34m 20s** | **31** | |

Turn three dominated: as context reached 47K, each tool-call round-trip added over two minutes' prefill. Failed edits further increased time. Investigation and analysis were brisk; the fix turn, with context growth and errors, was slow. Better hardware would improve the fix turn.

One honest data note: turn two emitted roughly 20K characters of reasoning despite `MAX_THINKING_TOKENS=0`. Either the setting didn't apply to that session or the model routed reasoning into normal output — the same fragility flagged in Post 6. It didn't derail the run, but it's why the analysis turn ran longer than its five tool calls suggest.

## What this proves, and what it doesn't

It proves the loop closes. A local, air-gapped model took a real incident from alert to an open pull request — found the same root cause as the frontier, wrote an equivalent fix, and filed the PR — on a 36 GiB laptop. For a team that can't send cluster data or source across the firewall, that is the whole question, and the answer is yes.

While the local run matched the frontier in outcome, it was slower and less polished: 34 minutes, two failed edits, and manual skill use. Local Claude Code does SRE work—slower and rougher, but delivers when no AI alternative exists.

And it's one machine's story. Everything here ran on a 36 GiB M3 Pro, and I haven't tried it on faster Apple Silicon — the speed limits are the first thing that should lift on a Max, an Ultra, or more memory. If you run this stack on better hardware, publish your numbers; I'd like to see how far they move, and so would anyone else weighing the local path.

One machine, one scenario: an anecdote—not a measurement. The next post fills that gap; it runs the full k8s-ai-bench suite on both models to put numbers on quality. This is depth; next is breadth.

---

The adapted skill, the `CLAUDE.md`, the scenario, and PR #7 are in the repo at [`claude-code-sre-handbook`](https://github.com/har-ki/claude-code-sre-handbook) — clone it and run the same three prompts against your own local model.

---

*Working through this on your own infrastructure? Happy to jam — drop me a line.*
