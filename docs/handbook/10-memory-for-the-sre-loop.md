
# 10 — Memory for the SRE Loop

*Files in a directory. That's the whole memory system.*

The watcher from [Post 5](05-building-the-always-on-watcher.md) closes the SRE loop — alert to draft PR in five minutes. But every incident starts cold. The same `StockMismatchError` fires on the same race condition, and the agent re-discovers the same TOCTOU bug from scratch, every time. Prior resolutions exist; the agent just can't see them.

This post adds memory. Not a product, not a vector store — a file convention. The result is [`watcher-memory-example/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-memory-example), a standalone variant of the watcher that reads prior findings before investigating and persists new findings after fixing. The evidence is a real capture against the ecommerce demo's inventory race condition, run on Sonnet 4.6.

## Memory is a convention, not a tool

The watcher already fingerprints each incident: `sha256(f"{service}|{exception_class}")[:8]`. The ecommerce race condition fingerprints to `e2836e74`. That hash already drives dedup against open PRs. Memory reuses it as a filename.

```
memory-store/
├── incidents.jsonl          # append-only log (unchanged from Post 5)
└── incidents/
    └── e2836e74.md          # root cause + fix pattern from prior resolution
```

Each `<sha8>.md` file is plain markdown — a root cause paragraph, a fix pattern paragraph, and a resolution date. No schema enforcement, no indexing, no new dependency. The agent reads these files with the `Read` tool and writes them with `Write` — the same file tools it already uses for source code. Memory is not a capability the agent has; it's a convention the prompt enforces.

## The build

The memory convention wires into the existing two-phase architecture. The structural invariants from Post 5 are unchanged: two separate `claude -p` invocations (never collapsed), `--allowedTools` filtering every Bash call, `gh pr ready` absent from both phases (the human gate), `--max-turns 40`, `--output-format stream-json --verbose`.

### Phase 1 reads memory before investigating

The investigation prompt gains a new first step:

```markdown
## Prior findings (memory)

1. Read the file `/memory-store/incidents/${FP_HASH}.md` using the Read tool.
2. If the file exists, use it as context for your investigation.
   Note in your findings that a prior finding was loaded.
3. If the file does not exist, proceed with a fresh investigation.
```

The `Read` tool is already in Phase 1's `--allowedTools`. No filter change needed.

### Phase 2 writes memory — explicitly prompted

After proposing the fix, Phase 2 must persist the finding:

```markdown
9. **Persist findings to memory store.** Write the root cause and fix pattern
   to `/memory-store/incidents/${FP_HASH}.md` using the Write tool.
   Use this exact format:

   # Prior Finding: ${FP_HASH}
   ## Root Cause
   <one paragraph>
   ## Fix Pattern
   <one paragraph>
   ## Resolved
   ${DATE} via PR #${PR_NUM}

   This step is REQUIRED — do not skip it.
```

The emphasis is deliberate. In testing, unprompted write-initiative — the model deciding on its own to persist a finding — fired only 40–60% of the time. That's a coin flip. The write must be an explicit, numbered step in the prompt with a "REQUIRED" marker, not something you hope the model does. Forced writes fired 100% of the time in both the plumbing test and the canonical capture.

### Guardrails

The memory filename is derived only from the computed `sha256` hash, never from model-supplied text. The orchestrator (`main.py`) validates the hash with a regex (`^[0-9a-f]{8}$`) and a `realpath()` containment check before any file operation:

```python
def validate_memory_path(fp_hash: str) -> str | None:
    if not re.match(r'^[0-9a-f]{8}$', fp_hash):
        return None
    path = os.path.join(MEMORY_INCIDENTS_DIR, f"{fp_hash}.md")
    resolved = os.path.realpath(path)
    if not resolved.startswith(os.path.realpath(MEMORY_INCIDENTS_DIR) + os.sep):
        return None
    return path
```

The agent cannot write outside `memory-store/incidents/`. The `--allowedTools` scope is unchanged — memory access goes through `Read` and `Write`, which are already permitted. No Bash filter was widened.

## The canonical capture

One cold run (no prior memory) and one warm run (same fingerprint, prior finding present). Sonnet 4.6, real otel-demo cluster (`kind-claude-sre-demo`), real ClickHouse queries, real `StockMismatchError` errors from product 7 under load. Fingerprint: `ecommerce-api|StockMismatchError`, sha8 `e2836e74`.

| Run | Phase | Turns | Wall-clock | Cost | Memory |
|-----|-------|-------|------------|------|--------|
| Cold | 1 — investigate | 12 | 87s | $0.19 | miss |
| Cold | 2 — fix + write | 6 | 58s | $0.13 | **write fired** |
| Warm | 1 — investigate | 14 | 74s | $0.19 | **hit** |
| Warm | 2 — fix + write | 9 | 79s | $0.19 | write (update) |

These are single-run data points, not performance benchmarks. The warm run was not faster — 14 turns versus 12. Do not read a speed claim into this table; that's Post 11's job with a proper matrix.

### Cold run: miss, fix, forced write

Phase 1 read `/memory-store/incidents/e2836e74.md`, got a file-not-found error, and logged `> **Memory:** No prior finding for fingerprint e2836e74`. It then ran the full investigation: ClickHouse queries, kubectl pod health, source code analysis. Identified the TOCTOU race in `inventory.js:39–55` — async `getStock()` read, 50–150ms inline delay, non-atomic decrement — with high confidence.

Phase 2 proposed a per-product async mutex (`acquireLock(productId)`) wrapping the read-check-decrement critical section in `try/finally`. Correct fix, equivalent to the known resolution from Post 2. Then the forced write fired. Both evidence paths confirm it:

1. **File on disk:** `memory-store/incidents/e2836e74.md`, 1,682 bytes.
2. **Stream-json audit log:** `"name":"Write"` tool call with `file_path` targeting `memory-store/incidents/e2836e74.md`.

The memory file's Root Cause section, verbatim from `memory-store/incidents/e2836e74.md`:

> `reserveInventory()` in `otel-demo/ecommerce/backend/src/services/inventory.js` has a TOCTOU race condition across lines 39–55. The function reads stock via `await getStock(item.id)` (5 ms simulated DB delay), validates `currentStock >= item.quantity`, then sleeps 50–150 ms for "business rule validation," and only then decrements `inventory[item.id]`. Because Node.js yields control at every `await`, multiple concurrent coroutines can all read `currentStock = 5`, all pass the pre-decrement check, and all proceed to decrement — driving stock negative. Product 7 (Ceramic Plant Pot) is uniquely affected because it is initialized with only 5 units while all other products have 50; under load from 3 concurrent load-generator pods requesting quantity 2, the race window (55–155 ms) is wide enough to exhaust product 7's stock within seconds of startup.

And the Fix Pattern section:

> Introduce a per-product promise-chain mutex (`acquireLock(productId)`) using no external dependencies. Add a module-scoped `locks` object and a 6-line `acquireLock` helper immediately after the `inventory` declaration. Before the `getStock` call for each item, acquire the lock; release it in a `finally` block after the decrement. This makes the read-check-decrement sequence atomic per product, eliminating the TOCTOU window.

### Warm run: hit, corroborate, proceed

Phase 1 read the same path, found the file, and loaded it. The findings file opens with:

> **Memory:** Prior finding loaded from `/tmp/watcher-memory-capture/memory-store/incidents/e2836e74.md`

Then quotes both Root Cause and Fix Pattern sections in full blockquotes before running fresh ClickHouse queries. The agent didn't blindly trust the memory — it corroborated. It queried the last 15 minutes of errors, checked pod health, re-read the source code, and arrived at a confidence assessment that explicitly cross-references the memory. From the findings file's Confidence section:

> **HIGH (95%)** — Prior memory finding matches exactly:
> - Same product (Product 7 / Ceramic Plant Pot)
> - Same mechanism (TOCTOU at lines 39–55)
> - Same stock floor observed (`-3` in logs, consistent with 3-pod concurrent decrement of initial stock 5)
> - 3 load-generator pods confirmed running (exact scenario described in memory)
> - Source code confirms the race window is unchanged — no mutex present

That corroboration behavior — memory as starting hypothesis, not as authority — is the healthy pattern. The agent treated the prior finding as a lead to verify, not an answer to accept. This emerged from the prompt structure (memory is read *before* the investigation steps, not *instead of* them) and from the model's own judgment. It wasn't something I engineered; it's something I observed and want to preserve.

### Observations from the capture

The `--allowedTools` filter worked as intended. No `gh pr ready` appeared in any phase. No writes landed outside `memory-store/incidents/` or the designated results directory. The hash `e2836e74` was identical across all four phase invocations — deterministic, computed by the orchestrator, never by the model.

One thing worth noting for anyone designing an allow-list gate: the agent, denied `Bash(mkdir -p ...)` by `--allowedTools`, didn't stop — it fell through to the `Write` tool, which creates parent directories implicitly. In one case it retried the denied call with `dangerouslyDisableSandbox: true`, attempting to override the filter. A denied tool isn't a stopped intent, only a redirected one. In production this wouldn't occur — `main.py` calls `os.makedirs()` before invoking the runner — but the capture script didn't pre-create the directory, and the agent's recovery path is the real behavior under that condition.

The fix quality was consistent: both cold and warm runs proposed the same per-product async mutex pattern. In this run, the warm Phase 2 didn't produce a meaningfully different fix — plausibly because Phase 2 already receives the root cause from the orchestrator's PR-body parsing, though one run can't establish where memory helps most.

Audit logs, memory files, and the capture harness are in [`watcher-memory-example/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-memory-example).

## Where it breaks

This memory system has one retrieval mechanism: exact hash match. `sha256("ecommerce-api|StockMismatchError")[:8]` hits `e2836e74.md` or it doesn't. Two failure modes follow.

**Different root cause, same exception.** The ecommerce service throws `StockMismatchError` from a different code path — say, a database migration bug instead of a race condition. The fingerprint hashes identically. Phase 1 loads the prior finding about the TOCTOU race and starts investigating a lead that doesn't apply. Memory becomes misdirection.

**Same root cause, different exception.** The race condition resurfaces but now throws a different exception class — maybe the error handling was refactored. The fingerprint hashes differently. Phase 1 finds no prior memory and investigates from scratch, despite a directly relevant finding sitting one hash away.

Both failures stem from the same limit: the dedup hash is a content-addressing scheme, not a semantic one. It works when the incident signature is stable. It breaks when the surface changes but the substance doesn't, or vice versa.

Semantic recall — vector similarity over past findings, retrieval-augmented context, tools like mem0 — exists precisely for this fuzzy-match case. Whether adding it actually helps, or whether it introduces more misdirection than it prevents, is a testable question. That's the next post.

---

*Building memory into your own watcher? Happy to jam — [drop me a line](https://github.com/har-ki).*
