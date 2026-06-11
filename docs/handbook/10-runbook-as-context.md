# 10 — Runbooks as Context

The first thing to put in an SRE agent's window isn't data—it's a clear procedure. This post shows how having a runbook changes an agent's behavior, and how to write one that actually helps.

When building context for an agent, the first big decision is what information to show. Most people focus on data or logs, but the often-missed ingredient is procedural knowledge—a runbook showing how to investigate, in what order, and with what checks.

Most people feel that runbooks are helpful, but this post backs it up with data from a real incident, testing only the effect of procedure. The finding is simple but powerful: a runbook doesn't just help the agent—it makes its actions repeatable. With a runbook, the agent investigates the same way every time, instead of taking a different approach on each run.

## The experiment

The experiment used a single incident: the classic StockMismatchError race in inventory.js, where async operations let orders oversell stock. The same model (Claude Sonnet 4.6) was used throughout. The only variable changed was the procedural context given to the agent.

* Arm A: No Skill. The agent had full tool access but no procedure to follow.
* Arm B: Thin Skill. The agent got location hints—what logs and tables to check, what columns mean—but no step-by-step method.
* Arm C: Full Runbook. The agent got a detailed three-phase procedure (INVESTIGATE → CORROBORATE → CONCLUDE), with clear instructions to cross-check at least two kinds of evidence and list every contributing factor before finishing.

Arms B and C carry the same facts. The only thing C adds is method. That's deliberate: if C had known anything B didn't — an extra table, a hint toward the bug — the experiment would measure knowledge, not structure. It doesn't. It measures structure, and that is what separates the arms.

Each arm ran three times, for a total of nine runs. Memory was disabled the whole time, so recall couldn't affect the results. The pod was reset between every run so no run picked up inventory issues from another. Total cost: $1.24. The runner, skills, and analysis script are all in the repo — `benchmark/bin/run-post10-experiment.sh --all` reproduces the full experiment on your own cluster.

## What the runbook changed

Here's what happened. The most important numbers aren't the averages, but how much the results varied between runs—that's where the arms really differ.

| Arm | Mean tool calls | Tool-call CV | Path divergence (Jaccard) |
|---|---|---|---|
| A — No Skill | 10.3 | 0.241 | 0.622 |
| B — Thin Skill | 8.0 | 0.177 | 0.683 |
| C — Full runbook | 10.7 | 0.044 | 0.256 |

Two columns tell the story.

The coefficient of variation shows how much the number of tool calls changed between runs. Lower means more consistent. No Skill: 0.241. Full runbook: 0.044—the runbook made tool use much steadier.

Path divergence shows whether the agent followed the same steps each time, not just the same number. Lower means more similarity. No Skill: 0.622 (the agent took a different path every run). Full runbook: 0.256 (much more consistent routes).

That's the core result: the full runbook didn't make the agent faster. In fact, it used a few more tool calls than the bare agent. But it made the investigation repeatable—three runs, three similar investigations. Without a runbook, you got three different approaches to the same problem.

## Why repeatability is the point

For an SRE, a faster investigation is nice. A repeatable one is the thing that matters, and it's worth being clear about why.

If an agent acts differently every time, you can't trust or improve it. You can't review its work, do a proper postmortem, or pass the output to a teammate and expect clear reasoning. Repeatability is what makes an agent a real tool—you know what it's going to do, and you can spot when it's wrong.

The bare agent (Arm A) didn't do a bad job—it was just inconsistent. And inconsistency erodes trust faster than almost anything in production. The runbook's job isn't to make the agent smarter; it's to make it predictable.

## The thin Skill is not a halfway point

It's tempting to see the three arms as a simple gradient: more procedure means more benefit. But the data says otherwise.

The thin Skill (Arm B) made the agent faster and more direct, using fewer tool calls and inspecting fewer files. But its paths varied even more between runs than the bare agent. Hints made the agent quicker, but not more consistent—it just took different shortcuts each time.

So, hints and methods serve different purposes. Hints save effort—point the agent in the right direction and it goes there quickly. Method (procedure) brings consistency—give it phases and checks, and it follows the same process every time, even if it takes a bit longer. These aren't two ends of a spectrum. If you want speed, hints work. If you want trust and review, you need procedure. The middle arm isn't a halfway point—it's just a different approach.

## How to write a runbook that helps

The full runbook worked because of its structure. Four key elements made the difference:

**Use phases, not checklists.** The runbook had three named phases: INVESTIGATE, CORROBORATE, and CONCLUDE. Phases give the agent clear steps and checkpoints. For example, the CORROBORATE phase forced the agent to double-check its findings before wrapping up. Checklists get skimmed; phases require action.

**Make corroboration explicit.** The runbook told the agent to cross-check at least two kinds of evidence before concluding. Without this, the agent might stop at the first clue. With it, it had to find the same story in logs, traces, and code before wrapping up.

**Add an instruction to enumerate every contributing factor.** This keeps the agent from stopping at the first cause. Real incidents often have more than one thing going wrong, and this step helps catch them all.

**Keep facts and method separate.** The runbook should contain just the procedure. All facts—like table schemas or log locations—should live somewhere else. Mixing them makes runbooks hard to update and bloats your context window. Keep the method stable and update facts as needed.

One honest note from the runs: the runbook's templated ClickHouse query had a shell-escaping bug — a backslash that broke the SQL on one run. The agent noticed the syntax error and rewrote the query itself. Templated commands in a runbook are conveniences, not contracts; the agent will route around a broken one, but a clean template is one less thing for it to spend a turn fixing.

## What this proves, and what it doesn't

This experiment proves that procedural context really matters: the runbook cut path divergence from 0.622 to 0.256, and tool-call variance from 0.241 to 0.044. The agent became repeatable because it had procedure in its context. Repeatability isn't luck—it's engineered.

It doesn't prove these results hold for every kind of incident—this was just one scenario, tested deeply. It also doesn't claim the runbook made the agent correct; it just made it consistent. Whether speed sacrifices thoroughness is a question for another post.

The takeaway: don't just give your agent more data—give it a method. Write the procedure in phases, build in corroboration and enumeration, and keep facts separate. That's how you make investigations repeatable—even if it doesn't guarantee perfect answers.

The next post is about what happens when the agent has every signal and still can't assemble the story — because procedure gets you a repeatable investigation, but repeatable isn't the same as correct.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
