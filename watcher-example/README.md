# Watcher Example — Always-On Incident Response

Reference implementation of the always-on watcher described in
[Post 5: Building the Always-On Watcher](../docs/handbook/05-building-the-always-on-watcher.md).

The watcher polls ClickHouse for elevated error rates, opens a draft PR
on this repo, then invokes Claude Code headless to investigate
(Phase 1) and propose a fix to the ecommerce app at `otel-demo/ecommerce/backend/`
(Phase 2). The PR stays draft — a human reviewer is the only un-draft path.

Self-contained: the ecommerce app, ClickHouse, OTel bridge, and load
generator all live in `otel-demo/`. No external fork required.

## Prerequisites

- Docker and Docker Compose
- The `otel-demo` stack running (`../otel-demo/setup.sh`)
- `gh` CLI authenticated (`gh auth login`)

## Environment variables

Copy `.env.example` to `.env` and fill in:

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude Code |
| `GH_TOKEN` | GitHub personal access token with `repo` scope |
| `CLICKHOUSE_HOST` | Optional, defaults to `localhost:9000` |

## Quick start

```bash
# 1. Start the otel-demo stack (if not already running)
cd ../otel-demo && ./setup.sh

# 2. Bootstrap labels and incident structure (one-time)
./scripts/bootstrap-fork.sh har-ki/claude-code-sre-handbook

# 3. Configure
cp .env.example .env
# Edit .env with your keys

# 4. Start the watcher
docker compose up -d

# 5. Drive traffic
../otel-demo/scripts/start-load-gen.sh
```

## What to expect

Within ~5 minutes of the error rate crossing 25%:

1. A draft PR appears on this repo: `[INVESTIGATING] ecommerce-api elevated error rate (XX%)`
2. Phase 1 fills in the Investigation section (~45s)
3. Phase 2 commits a fix + incident report, flips label to `incident:fix-proposed` (~2min)
4. The PR remains **draft** — review the diff and incident report, then un-draft and merge

## Audit log

Stream-json output from each Claude Code invocation lands in:

```
audit-log/incident-<fp_hash>-phase1.jsonl
audit-log/incident-<fp_hash>-phase2.jsonl
```

Incident records accumulate in `memory-store/incidents.jsonl`.

## Cost

Using `claude-sonnet-4-6` (default), a typical incident lands well under $1
total across both phases. Observed: Phase 1 ~$0.22 (11 turns), Phase 2 ~$0.20
(11 turns). Total ~$0.42 per incident.

## Tear down

```bash
docker compose down
```

To also tear down the otel-demo: `../otel-demo/teardown.sh`
