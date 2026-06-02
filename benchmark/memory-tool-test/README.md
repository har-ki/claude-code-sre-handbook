# Memory-Tool Test Harness (Phase 10)

Minimal test harness that answers three questions about Claude Code's memory tool:

1. **Stack** — Does each transport (API / Ollama) expose the memory tool type?
2. **Drive** — Does each model check `/memories` first, write coherent entries, and recall them?
3. **Gap** — What's the Sonnet-vs-Qwen difference: initiative (Tier 1) vs. capability (Tier 2)?

Results feed Post 12's form decision and tell Phase 12 whether the watcher gets memory
on initiative or via prompt instruction.

## Pinned Versions

| Component | Version |
|-----------|---------|
| Claude Code | 2.1.84 |
| Ollama | 0.24.0+ |
| Qwen model | qwen3.6:35b-a3b-coding-nvfp4 |
| Python | 3.10+ |
| jq | 1.6+ |

## Prerequisites

- `claude` CLI in PATH
- `python3` and `jq` installed
- For the Qwen profile: `ollama serve` running with model pulled, `OLLAMA_MLX=1`

## Quick Start

```bash
# Step 1: Stack probe (run for each profile)
./run-memory-test.sh --profile profiles/sonnet.env --step 1
./run-memory-test.sh --profile profiles/qwen.env   --step 1

# Step 2: Drive test (only if Step 1 passes for that profile)
# Full run: both phases, both tiers, 5 iterations each
./run-memory-test.sh --profile profiles/sonnet.env --step 2 --tier implicit
./run-memory-test.sh --profile profiles/sonnet.env --step 2 --tier explicit
./run-memory-test.sh --profile profiles/qwen.env   --step 2 --tier implicit
./run-memory-test.sh --profile profiles/qwen.env   --step 2 --tier explicit

# Single-phase debug run
./run-memory-test.sh --profile profiles/sonnet.env --step 2 --phase 1 --tier explicit --iterations 1
```

## Architecture

```
profile.env ─→ run-memory-test.sh ─→ claude -p ─→ stream-json-filter.py ─→ trace.jsonl
                                                                              ↓
                                                                   parse-memory-trace.py
                                                                              ↓
                                                                  benchmark/data/raw/*.jsonl
```

## Output

### Step 1 JSONL (stack probe)

```json
{
  "timestamp": "20260602T120000",
  "model": "claude-sonnet-4-6",
  "step": "stack-probe",
  "claude_code_version": "2.1.84",
  "profile": "sonnet",
  "tool_type_present": true,
  "tool_use_emitted": true,
  "error": null
}
```

### Step 2 JSONL (drive test)

```json
{
  "timestamp": "20260602T120100",
  "model": "claude-sonnet-4-6",
  "step": "drive-test",
  "tier": "implicit",
  "phase": 1,
  "iteration": 1,
  "checked_first": true,
  "wrote_coherent": true,
  "recalled": null,
  "tool_calls": 3,
  "tool_call_sequence": ["read", "write", "read"],
  "malformed": 0,
  "claude_code_version": "2.1.84",
  "profile": "sonnet"
}
```

Files land in `benchmark/data/raw/` using the naming convention:
`YYYYMMDD-T-memtest-<model-slug>-<step-detail>.jsonl`

## Known Risks

- **Memory tool is client-executed**: Claude Code runs `/memories` file ops locally.
  Whether it's offered depends on Claude Code version and the `ANTHROPIC_BASE_URL` shim.
- **Tool name unknown until first probe**: The exact tool name (e.g., `Memory`, `UserMemory`)
  is discovered by Step 1. `parse-memory-trace.py` uses a configurable regex
  (`MEMORY_TOOL_PATTERN` env var, default: `memory`).
- **`--dangerously-skip-permissions` may suppress tools**: If Step 1 shows
  `tool_type_present: false` for the API profile, try without this flag.
- **Ollama may not support memory tool type**: This is finding (a), not a bug.

## Profiles

Each `.env` file in `profiles/` sets:

| Variable | Purpose |
|----------|---------|
| `MODEL` | Model identifier for `--model` flag |
| `ANTHROPIC_BASE_URL` | Override for Ollama path (omit for API) |
| `MAX_BUDGET_USD` | Budget guard; 0 = omit the flag (Ollama is free) |

To add a new profile, create a new `.env` file following the same pattern.

## Tiers Explained

| Tier | What it tests | Why it matters |
|------|---------------|----------------|
| **Implicit (Tier 1)** | Model uses memory tool without being told | Tests initiative — will the model reach for persistence unprompted? |
| **Explicit (Tier 2)** | Model uses memory tool when instructed | Tests capability floor — can the model use the tool at all? |

Qwen passing Tier 2 but failing Tier 1 is a clean, publishable result:
tool works locally, model won't reach for it unprompted.
