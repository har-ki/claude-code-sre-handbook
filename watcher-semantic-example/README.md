# watcher-semantic-example

Semantic-memory variant of the SRE incident watcher. Adds similarity-based
retrieval (via local embeddings) and validation discipline as toggleable
layers on top of the file-based memory convention from `watcher-memory-example/`.

Self-contained. Does not import from or modify the other watcher examples.

## Embedding model

- **Model:** `nomic-embed-text` (274 MB, 768-dimensional)
- **Runtime:** Ollama (local, air-gapped compatible)
- **Similarity scores are model-specific.** Threshold values calibrated for
  this model are not transferable to other embedding models.

## Three config knobs

All set in `alert-watcher/config.yaml`, no code edits needed:

```yaml
# Retrieval mode: exact (SHA256-hash lookup) or similarity (cosine search)
retrieval_mode: similarity    # exact | similarity

# Minimum cosine similarity to surface a finding (similarity mode only)
similarity_threshold: 0.75

# When true, Phase 1 must classify the prior finding as
# validated / invalidated / inconclusive before using it
validation_discipline: true   # true | false
```

## Architecture

```
watcher-semantic-example/
├── alert-watcher/
│   ├── main.py               # Orchestrator with configurable retrieval
│   ├── semantic_memory.py     # Embedding, indexing, retrieval layer
│   └── config.yaml            # Three toggles + standard config
├── claude-runner/
│   ├── invoke.sh              # Two separate claude -p phases
│   └── workspace-claude.md    # Model orientation (includes memory docs)
├── prompts/
│   ├── 01-investigate.md      # Phase 1: retrieval metadata + validation discipline
│   └── 02-propose-fix.md      # Phase 2: fix + required memory write
├── memory-store/
│   ├── incidents/             # Per-incident findings (<sha8>.md)
│   └── embeddings/            # Vector index (index.json)
├── test-incidents/            # Three test cases (see below)
├── seed-memory.sh             # Seeds memory + builds vector index
└── verify-retrieval.sh        # Verifies retrieval against all test cases
```

### Locked invariants (same as watcher-memory-example)

- Two separate `claude -p` phases (never collapsed)
- `--max-turns 40`, `--output-format stream-json --verbose`
- `gh pr ready` absent from all `--allowedTools` (human gate)
- Memory paths validated via regex + `realpath()` containment

## Retrieval modes

### Exact (baseline)

Same as `watcher-memory-example/`. Looks up `memory-store/incidents/<sha8>.md`
by the fingerprint hash. Hits only on identical `service|exception_class`.

### Similarity

Embeds the incident description via `nomic-embed-text`, searches the vector
index by cosine similarity. Returns the nearest finding if the score exceeds
`similarity_threshold`; stays silent otherwise (safe-silence default).

**Index format:** Flat JSON file at `memory-store/embeddings/index.json`.
Each entry stores the embedding, service, exception class, and fingerprint hash.
Sufficient for hundreds of findings (not designed for millions).

**Embedding strategy:**
- Stored findings use `search_document:` prefix with finding content (rich)
- Queries use `search_query:` prefix with expanded exception context
- CamelCase exception names are split for semantic signal
  (`StockMismatchError` → `stock mismatch error`)

## Validation discipline

When `validation_discipline: true`, Phase 1's prompt requires an explicit
classification before using the prior finding:

```
> **Validation: VALIDATED** — prior finding matches because ...
> **Validation: INVALIDATED** — prior finding does NOT match because ...
> **Validation: INCONCLUSIVE** — cannot confirm, investigating further
```

If INVALIDATED, the agent must investigate from scratch. This is designed
to catch the "recall-anchoring" failure mode where a partial match causes
the agent to stop investigating too early.

## Test incidents

Three test cases in `test-incidents/`:

| Test | Fingerprint | Exact hash | What it tests |
|------|-------------|------------|---------------|
| **Canonical** | `ecommerce-api\|StockMismatchError` | `e2836e74` | Baseline — should find and validate |
| **Drift** | `ecommerce-api\|InventoryValidationError` | `de61efe2` | Renamed exception. Exact misses, similarity finds. |
| **Near-miss** | `ecommerce-api\|StockMismatchError` | `e2836e74` | Same hash, different cause (cache bug). Both modes find it — tests whether validation discipline catches the mismatch. |
| **No-precedent** | `ecommerce-api\|PaymentGatewayTimeout` | `2c8fc300` | No relevant finding. Both modes should stay silent. |

### Verified retrieval scores (nomic-embed-text)

| Test | Exact | Similarity score | Above 0.75? |
|------|-------|-----------------|-------------|
| Canonical | hit | 0.80 | yes |
| Drift | miss | 0.81 | yes |
| Near-miss | hit | 0.80 | yes |
| No-precedent | miss | 0.74 | **no** (silent) |

## Quick start

```bash
# 1. Ensure Ollama is running with the embedding model
ollama pull nomic-embed-text

# 2. Seed memory with the canonical finding + build vector index
bash seed-memory.sh

# 3. Verify retrieval works for all test incidents
bash verify-retrieval.sh

# 4. Run the watcher (requires otel-demo cluster + Docker)
cp .env.example .env
# Fill in ANTHROPIC_API_KEY and GH_TOKEN
docker compose up -d --build
```

## Switching modes between runs

Edit `alert-watcher/config.yaml`:

```yaml
# Run 1: exact-hash baseline
retrieval_mode: exact
validation_discipline: false

# Run 2: similarity with discipline
retrieval_mode: similarity
validation_discipline: true

# Run 3: similarity without discipline (to see if discipline matters)
retrieval_mode: similarity
validation_discipline: false
```

No code changes, no rebuild. The config is read at watcher startup.
