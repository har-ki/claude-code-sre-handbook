# watcher-complete

The complete SRE watcher — Part 3 context engineering plus Part 4 learning, integrated into a single standalone system you can clone and run on your own cluster.

Built for Post 17 of the Claude Code SRE Handbook series.

## What it does

1. **Detects** elevated error rates by polling ClickHouse (OTel data).
2. **Deduplicates** against open PRs via fingerprint labels.
3. **Opens a draft PR** with trigger metadata.
4. **Phase 1 — Investigate:** Recalls prior findings with outcome data (including lessons from past merges), applies validation discipline, correlates logs + traces + code, writes Investigation section to PR body.
5. **Phase 2 — Propose fix:** Writes minimal fix, commits, creates incident report, persists finding to memory store with `outcome=pending`.
6. **Phase 3 — Learn (on merge/close):** Compares original finding against merged diff, writes verdict + lesson via `record_outcome()`. Fires asynchronously when a human merges or closes the PR.

The human gate is between Phase 2 and Phase 3: the PR stays in draft until a reviewer un-drafts and merges it. Phase 3 reads the outcome of that gate — it never touches it.

## Architecture

### Three phases, two triggers

| Phase | When | What | allowedTools |
|-------|------|------|--------------|
| 1 — Investigate | Alert detected | Query cluster, recall memory + lessons, correlate, write PR Investigation | ClickHouse, kubectl, gh pr view/edit/comment, Read, Write, Glob, Grep |
| 2 — Propose fix | Phase 1 succeeds | Write fix, commit, persist finding | git, gh pr view/edit/comment, Edit, Write, Read, Glob, Grep |
| 3 — Learn | PR merged/closed | Diff finding vs merged code, write lesson | git diff/log, gh pr view, Read, Write, Glob, Grep |

`gh pr ready` is absent from all phases. The human un-draft gate is the only checkpoint.

Phase 3 triggers:
- **GitHub Action** (`.github-workflow/learn-on-merge.yml`) — primary, on `pull_request: closed`
- **Poll script** (`scripts/poll-pr.sh`) — secondary, for local/air-gapped environments

### Outcome-bearing store

Every finding carries three nullable fields alongside its text and embedding:

| Field | Type | Default | Written by |
|-------|------|---------|------------|
| `outcome` | pending / merged / merged_modified / closed_unmerged | pending | Phase 3 |
| `verdict` | string | null | Phase 3 |
| `lesson` | string | null | Phase 3 |

`recall()` returns the finding plus its outcome/verdict/lesson. Most findings have null outcome fields — that's the normal operating regime.

### Two-store split

| Store | Contents | Written by | Read by |
|-------|----------|------------|---------|
| `memory-store/` | Per-fingerprint findings + embeddings + lessons | Phase 2 (finding), Phase 3 (outcome) | Phase 1 |
| `incident-store/` | `incidents.jsonl` structured metadata | Orchestrator | Humans, compliance |

## Directory structure

```
watcher-complete/
  alert-watcher/          # Orchestrator
    main.py               # Detection loop, PR management, phase execution
    store.py              # Outcome-bearing store (SQLite + JSON backends)
    config.yaml           # Configuration
    Dockerfile, requirements.txt
  claude-runner/          # Headless Claude Code invoker
    invoke.sh             # Phase 1/2/3 orchestration
    workspace-claude.md   # Workspace orientation
    Dockerfile
  prompts/
    01-investigate.md     # Phase 1 — with outcome/lesson awareness
    02-propose-fix.md     # Phase 2 — unchanged from capstone
    03-learn.md           # Phase 3 — learning phase
  templates/              # PR body and incident report templates
  skills/sre/             # Investigation runbook
  scripts/
    invoke-learn.sh       # Learning phase entrypoint
    poll-pr.sh            # Poll-based merge trigger
    seed-memory.sh        # Memory store initialization
    run-integrated-experiment.sh
    run-failure-mode-experiment.sh
  .github-workflow/
    learn-on-merge.yml    # GitHub Action trigger
  memory-store/           # Agent learnings
  incident-store/         # Orchestrator metadata
  audit-log/              # Phase execution trails
  experiments/
    17-integrated/        # Full loop experiment
    17-failure-mode/      # Bad merge experiment
  docker-compose.yml
```

## Running

### Prerequisites

Install these before running setup:

- **Docker** (with Docker Compose)
- **kind** — `brew install kind`
- **kubectl** — `brew install kubectl`
- **Ollama** — `brew install ollama`, then `ollama serve`
- **gh** — `brew install gh`, then `gh auth login`
- **ANTHROPIC_API_KEY** — from your Anthropic account

### Setup (one command)

The setup script creates the kind cluster, deploys the otel-demo stack (ClickHouse + OTel collector + ecommerce app with load generator), pulls the embedding model, seeds the memory store, and builds the Docker images.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./setup.sh
```

If you're running a fork, the script auto-detects your GitHub repo from `git remote` and updates `config.yaml`.

### Start the watcher

```bash
export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
export GH_TOKEN=$(gh auth token)
docker compose up
```

The watcher polls ClickHouse for elevated error rates. When it detects `StockMismatchError`, it opens a draft PR with investigation findings and a proposed fix.

### Run the learning phase (after merge)

After you merge or close the watcher's PR:

```bash
FP_HASH=e2836e74 \
FINGERPRINT='ecommerce-api|StockMismatchError' \
PR_NUM=<pr_number> \
GITHUB_REPO=<owner/repo> \
OUTCOME=merged \
./scripts/invoke-learn.sh
```

### Run experiments locally (no cluster needed)

```bash
./scripts/run-integrated-experiment.sh
./scripts/run-failure-mode-experiment.sh
```

## Canonical incident

- Service: `ecommerce-api`
- Exception: `StockMismatchError`
- Code: `inventory.js` — inline `setTimeout` L53, non-atomic decrement L55, throw L59
- Product: 7 "Ceramic Plant Pot" (stock 5)
- Fingerprint: `ecommerce-api|StockMismatchError` = `e2836e74`
- Cluster: `kind-claude-sre-demo` (ClickHouse + OTel)

## Honest limits

- **Slow signal.** The loop learns at merge speed — days, not minutes. This is correct: fast self-graded signal drifts; slow external signal grounds.
- **Sparse signal.** Most findings stay at `outcome=pending`. The store works in that regime.
- **Merge is a proxy, not proof.** A merge means a human approved the fix. It does not mean the fix is correct. The failure-mode experiment (`experiments/17-failure-mode/`) documents what happens when a bad merge teaches a wrong lesson — discipline can catch it, but not reliably. This is the merge-grounding wall.
