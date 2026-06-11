# watcher-memory-example

Memory-enabled variant of the SRE incident watcher. This is a standalone
example — it does not import from or modify `watcher-example/`.

## What's different from watcher-example

This variant adds a **file-based memory convention**. Memory is plain files
the agent reads and writes via the `Read`/`Write` tools — there is no
dedicated memory tool.

### Memory layout

```
memory-store/
├── incidents.jsonl          # Append-only incident log (same as watcher-example)
└── incidents/
    └── <sha8>.md            # Per-incident memory file (NEW)
```

Each `<sha8>.md` file contains the root cause and fix pattern from a prior
resolution, keyed by the dedup fingerprint hash.

### How memory flows through the phases

1. **Before Phase 1:** `main.py` checks `memory-store/incidents/<sha8>.md`
   and logs a memory hit or miss.
2. **Phase 1 (investigate):** The prompt instructs the agent to read the
   memory file. If found, it uses the prior finding as context and notes
   it in the PR Investigation section.
3. **Phase 2 (fix):** The prompt explicitly instructs the agent to write
   the root cause + fix pattern to `memory-store/incidents/<sha8>.md`
   after completing the fix. This is a required step, not optional.
4. **After Phase 2:** `main.py` verifies whether the memory write actually
   fired and logs the result.

### Guardrails

- Memory filenames are derived only from the computed sha256 hash, never
  from model-supplied text.
- Path traversal prevention: `validate_memory_path()` enforces `[0-9a-f]{8}`
  regex and `realpath()` containment checks.
- `gh pr ready` is deliberately absent from all phase `--allowedTools`.

## Quick start

```bash
cp .env.example .env
# Fill in ANTHROPIC_API_KEY and GH_TOKEN

docker compose up -d --build
```

## Verifying memory behavior in logs

Watch the alert-watcher logs for memory events:

```bash
docker compose logs -f alert-watcher | grep -E '"msg":"memory'
```

You should see:
- `"msg":"memory miss"` on the first occurrence of a fingerprint
- `"msg":"memory write verified"` after Phase 2 completes
- `"msg":"memory hit"` when the same fingerprint recurs

The `incidents.jsonl` records also include `memory_hit` and
`memory_write_verified` fields.
