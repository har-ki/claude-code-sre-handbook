# 02 — From Investigation to PR
*Skills for Claude Code*

*Three prompts, three Skill files, a real ecommerce bug. Six minutes later, a PR with a fix is open.*

Claude Code with Sonnet 4.6 and a small Skill resolved a race condition in inventory management from a vague error report — no prior codebase exposure, one continuous session from investigation through PR. Without the Skill, the same model and bug took over 13 minutes. With it, under six. That gap is the difference between an engineer context-switching vs. staying in flow.

[Post 1](01-harness-problem.md) argued that the harness shape matters more than the model behind it. This post puts a real Kubernetes cluster in front of that argument and times the loop. The Skill itself and its impact are introduced midway through the process.

## The scenario

The setup is a local kind cluster running an ecommerce service with observability wired in.

| Component | Detail |
|---|---|
| Kubernetes | kind, single control-plane node, v1.35.0 |
| Namespaces | `ecommerce` (app + load generator), `clickhouse` (CH + OTel bridge) |
| Observability | ClickHouse, OpenTelemetry collector, `otel-clickhouse-bridge` |
| Data | `otel_logs`, `otel_traces`, `otel_metrics_*` populated from live load |
| App | Node.js ecommerce service + checkout + inventory service |
| Failure mode | TOCTOU race in `reserveInventory` causing ~50% checkout error rate |

The bug is in `backend/src/services/inventory.js`. `reserveInventory` reads stock, waits 50--150 ms, checks requested quantity, then decrements stock non-atomically. Two concurrent reservations may read the same value, both pass the guard, and both decrement. For product 7 (Ceramic Plant Pot), stock drops to `-3` under load.

The model sees none of this in advance. It sees a running cluster with ClickHouse and OTel data, a repo it can clone (`ecommerce-app`), a `gh` CLI authenticated as the user, and whatever Skills are loaded in the session. No hints about the schema. No hint about the bug. No scope on the source repo beyond a name.

## The prompts

Three turns, identical across every session in this post.

```text
1. Ecommerce service is showing some errors in my local K8S cluster.
   Investigate and summarize errors. Use ClickHouse otel logs to
   identify the problem.

2. Source code for ecommerce service is in the repo ecommerce-app.
   Suggest a code fix for this issue.

3. Make code fixes in a private branch and create a pull request.
   Use GitHub integration (gh cli).
```

The prompts name "clickhouse," but no table, a repo but no path, a CLI but no branch convention. The model has to figure all of that out — and the third turn, where the agent does actual work in the world, is the one most demos skip.

## Baseline: Sonnet 4.6, no Skill

In the baseline run with Sonnet 4.6 and no Skills loaded, the process took 13 minutes and 27 seconds, requiring 99 tool calls over three turns to open a pull request. The process included several missteps that are worth noting.

Initially, the model attempted to connect to ClickHouse via the cluster’s NodePort but encountered network errors:

```text
$ clickhouse client --host 127.0.0.1 --port 30900
Connection refused (NETWORK_ERROR)

$ clickhouse client --host 172.18.0.3 --port 30900
Network is unreachable (NETWORK_ERROR)

$ kubectl exec -n clickhouse clickhouse-7ccb6ccb7-27x4p -- clickhouse-client
OK
```

Only after two failed attempts did it succeed by using kubectl exec to access ClickHouse inside the pod.

Additional time was spent discovering the schema, with several exploratory queries needed to find the relevant tables and columns. The model also used multiple overlapping LIKE queries for a single product, when a single targeted query would have sufficed resulting in unnecessary repetition.

Despite these challenges, the process ultimately succeeded, albeit inefficiently.

## The Skill

I designed Skills to solve common problems—like tricky connection setups, unclear schemas, repetitive workflows, and error recovery.
In Claude Code, a Skill is a markdown file with YAML frontmatter, stored either globally (in ~/.claude/skills/SKILL.md) or for a specific repository. At the start of each session, Claude Code loads any Skills that match the current context.
This repository includes three example Skills: ClickHouse, k8s, and gh. 

For instance, the ClickHouse Skill highlights important conventions and critical rules right at the top.

```yaml title="skills/clickhouse/SKILL.md"
---
name: clickhouse
description: >
  Query OTel observability data (logs, traces, metrics) via ClickHouse to
  investigate incidents. Use when the user mentions clickhouse, otel logs,
  otel traces, observability data, investigate traces, query metrics, or
  clickstack.
---

## Critical Rules

- Tables: `otel_logs`, `otel_traces`, `otel_metrics_gauge`,
  `otel_metrics_sum`, `otel_metrics_histogram`
- Time columns: `Timestamp` (logs, traces) vs `TimeUnix` (metrics)
- Service name: `ServiceName` (logs, traces) vs
  `ResourceAttributes['service.name']` (metrics)
- `SeverityText` varies — match with `IN ('ERROR','Error','error')`
- Exception details live in `LogAttributes` (Map), not in `Body`.
  Use bracket syntax, not LIKE.
- CLI binary: `clickhouse client` (two words, not hyphenated)
- Read-only access only; always include LIMIT and a time window

## Investigation Methodology

SCOPE -> TRIAGE -> DRILL -> MEASURE -> CORRELATE -> CONCLUDE

(Each phase has 1-2 canonical query templates...)
```

A Skill should capture practical tips and “tribal knowledge”: bracket syntax, common CLI commands, or how to handle exceptions. The model learns from these notes instantly, helping it avoid wasted steps and mistakes.
If you’re creating your own Skill, focus on what usually trips up new team members—quirky connections, column names that don’t match the docs, or query patterns people copy from chat. If it’s in your runbook but often ignored, it’s perfect for a Skill file.

The repo ships all three Skills (`clickhouse`, `k8s`, `gh`) under `skills/`. To install:

```bash
git clone https://github.com/har-ki/claude-code-sre-handbook
mkdir -p ~/.claude/skills
cp -r claude-code-sre-handbook/skills/* ~/.claude/skills/
```

Modify them to fit your stack. The file structure is more important than the specific contents.

## Sonnet 4.6, with the Skill

Same model, same scenario, same three prompts. Skills loaded from `.claude/skills/` at session start.

5 minutes 49 seconds, 9 tool calls in turn one, PR opened on first attempt.

The first ClickHouse query was no longer a guess:

```sql
SELECT max(Timestamp) FROM otel_logs;
```

Correct table and column, `clickhouse client` directly (no `kubectl exec`), case-insensitive severity from the next query. Zero schema-discovery round-trips. The model moved SCOPE -> TRIAGE -> DRILL -> MEASURE without looping and found product 7 in eight queries instead of twelve. Turn 3 was six tool calls: checkout, edit, commit, push, `gh pr create`, PR URL returned.

| Metric | No Skill | With Skill |
|---|---:|---:|
| End-to-end wall clock | 13:27 | 5:49 |
| Turn 1 tool calls | 99 (43 + 56 subagent) | 9 |
| Schema-discovery round-trips | 3 + 2 failed connections | 0 |
| Turn 3 errors | 2 | 0 |
| Root cause correct | Yes | Yes |

Root-cause accuracy didn't change — both sessions identified the TOCTOU and proposed a per-product async mutex. The Skill didn't make Sonnet smarter. It made Sonnet's tools hit the mark: 99 tool calls to 9.

## Where it still breaks

Two real limitations from these sessions.

**Skill discovery is brittle.** Skills load when their `description:` keywords match the user message. In the Sonnet+Skill run, a `gh` Skill never surfaced — Turn 3 said "github integration (gh cli)" but `gh` didn't load while `clickhouse` and `k8s` had loaded on Turn 1. The session succeeded anyway, but the failure mode is real: a Skill that doesn't load can't help, and there's no visible signal that it didn't.

**Skills don't cover phase transitions.** The investigation -> code-fix pivot — *clone the repo, read inventory.js, propose a diff* — is unguided. Every session figured it out; the figuring was first-principles reasoning.

Neither is a harness failure. The harness gave the model edit tools, retry, reasoning — all worked when called. The takeaway: a Skill doesn't need to be perfect. A short file that encodes your team's tribal knowledge about one tool cuts the investigation loop in half — and unlike a runbook, it's read every time.

## Try it yourself

Everything in this post is reproducible from the repo. You need Docker, [kind](https://kind.sigs.k8s.io/), kubectl, [Claude Code](https://claude.ai/claude-code), and the [GitHub CLI](https://cli.github.com/) (`gh`).

```bash
git clone https://github.com/har-ki/claude-code-sre-handbook
cd claude-code-sre-handbook/otel-demo
./setup-post02.sh
```

This stands up the kind cluster, pushes the ecommerce app to your GitHub, installs the Skills, and scales the load generator to trigger the bug. Authenticate `gh` first if you haven't (`gh auth login`).

Then open Claude Code and paste the three prompts one at a time. Compare your session against the results in this post.

Teardown: `./teardown.sh`

Your times and tool-call counts will vary — different cluster, different model snapshot, different day. The shape of the session should be the same.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
