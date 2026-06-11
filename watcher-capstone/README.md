# Watcher Capstone

The production-grade SRE incident watcher — integrates two-phase investigation (Phase 1: investigate, Phase 2: propose fix), semantic memory retrieval with validation discipline, and a SQLite storage backend.

This is the capstone assembly from the Part 3 series. It ports working code from `watcher-memory-example/` (orchestrator) and `watcher-semantic-example/` (semantic retrieval + validation discipline), with one new component: `store.py`, the pluggable storage backend.

## Quick start

### Prerequisites

- Docker and Docker Compose
- Ollama running locally with `nomic-embed-text` model pulled
- A Kubernetes cluster with the otel-demo workload deployed
- `ANTHROPIC_API_KEY` and `GH_TOKEN` set in `.env`

### Deploy

```bash
# 1. Copy env template and fill in secrets
cp .env.example .env

# 2. Seed the memory store with the canonical finding
OLLAMA_URL=http://localhost:11434 ./seed-memory.sh

# 3. Start the watcher
docker compose up --build
```

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ANTHROPIC_API_KEY` | Yes | Claude API key |
| `GH_TOKEN` | Yes | GitHub token with repo access |
| `CLICKHOUSE_HOST` | No | ClickHouse host:port (default: `localhost:9000`) |
| `OLLAMA_URL` | No | Ollama endpoint (default: `http://host.docker.internal:11434`) |
| `WORKSPACE_DIR` | No | Host path for workspace volume |
| `STORAGE_BACKEND` | No | `json` or `sqlite` (default: `sqlite`) |

### Kubeconfig

The watcher needs read access to your cluster. Mount your kubeconfig:

```bash
# Default: ~/.kube/config is mounted automatically via docker-compose.yml
# Override: set KUBECONFIG_HOST env var to a different path
```

## Storage backends

The `store.py` module provides two interchangeable backends behind the same `recall()`/`persist()` interface:

### JSON backend (`storage_backend: json`)

- Flat JSON file at `memory-store/embeddings/index.json`
- Ported verbatim from `watcher-semantic-example/alert-watcher/semantic_memory.py`
- Read-modify-write of the entire file on every persist
- Sufficient for single-instance deployments with low write frequency

### SQLite backend (`storage_backend: sqlite`)

- Single SQLite file at `memory-store/embeddings/findings.db`
- Schema: `findings(fp_hash PK, service, exception_class, finding_text, embedding BLOB, timestamp)`
- Atomic transactions via SQLite's built-in ACID guarantees
- Cosine similarity computed in Python after loading candidate rows — SQLite provides atomicity and consistency, NOT faster vector search

### Choosing a backend

| Axis | JSON | SQLite |
|------|------|--------|
| Write safety | Last-write-wins (no locking) | Atomic transactions |
| Search speed | Same (Python cosine scan) | Same (Python cosine scan) |
| Scale path | None — whole-file rewrite | `sqlite-vec` extension for in-DB vector search |
| Simplicity | Flat file, easy to inspect | Requires SQLite tooling |

**Default is SQLite.** For scale beyond hundreds of findings, the upgrade path is `sqlite-vec` — a SQLite extension for native vector similarity search. That extension is named here as the next step, not built.

## Window-edge tuning

Claude Code's context window behavior is configurable via environment variables. These are **operator configuration** — set them in your shell or `.env`, not in `config.yaml` or `main.py`:

```bash
# Auto-compact when context reaches this % of the window
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=0.8

# Maximum tokens per compact summary
export CLAUDE_CODE_AUTO_COMPACT_MAX_TOKENS=4000

# Disable auto-compact entirely (not recommended for long investigations)
export CLAUDE_CODE_AUTO_COMPACT=false
```

These variables are read by Claude Code at invocation time inside the claude-runner container. The watcher loop does not wire them — they pass through via the Docker env.

## Directory layout

```
watcher-capstone/
├── alert-watcher/          # Orchestrator (polls ClickHouse, manages PRs, runs phases)
│   ├── main.py             # Main loop (ported from watcher-semantic-example)
│   ├── store.py            # Storage interface + JsonBackend + SqliteBackend (NEW)
│   ├── config.yaml         # Watcher configuration
│   ├── Dockerfile
│   └── requirements.txt
├── claude-runner/          # Headless Claude Code invocation container
│   ├── invoke.sh           # Phase orchestration script
│   ├── workspace-claude.md # Workspace orientation for the agent
│   └── Dockerfile
├── prompts/
│   ├── 01-investigate.md   # Phase 1: investigation + memory read + validation
│   └── 02-propose-fix.md   # Phase 2: fix + REQUIRED memory write
├── skills/sre/             # Mounted runbook/skill for the agent
│   └── SKILL.md
├── templates/              # PR body and incident report templates
├── memory-store/           # Agent learnings — agent reads (P1) + writes (P2)
│   └── incidents/          # Per-fingerprint findings (<sha8>.md)
├── incident-store/         # Orchestrator-written metadata
│   └── incidents.jsonl     # Structured incident ledger
├── audit-log/              # Phase execution audit trails
├── docker-compose.yml
├── seed-memory.sh          # Initialize memory store + vector index
└── .env.example
```

<!-- INCIDENT_REPORT_CAUTION -->
