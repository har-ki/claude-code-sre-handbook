
# 11 — When Retrieval Isn't the Bottleneck

*Similarity search fixes drift. It can't fix a partial match. A prompt discipline can.*

[Post 10](10-memory-for-the-sre-loop.md) built file-based memory into the watcher and hit a wall: exact-hash retrieval fails silently when a signature drifts (renamed exception → different hash → no recall) and fails dangerously when a near-miss collides (same hash → recalls a finding that's incomplete for this incident). The obvious next step is better retrieval — replace the hash lookup with similarity search so findings surface by meaning, not by string identity.

This post tests that fix. It works for drift. It is provably powerless for the near-miss. And the thing that actually gets past the near-miss wall is a reasoning discipline in the prompt, not a retrieval upgrade.

## The retrieval upgrade

`watcher-semantic-example/` adds a similarity retrieval layer alongside the existing exact-hash lookup, toggled by a config knob (`retrieval_mode: exact | similarity`). Incidents are embedded via `nomic-embed-text` (274 MB, 768-dimensional, running locally through Ollama — air-gapped compatible). Stored findings are indexed in a flat JSON file with cosine similarity at query time. A `similarity_threshold` parameter controls the minimum score to surface a finding; below it, the system stays silent.

All similarity scores in this post are specific to `nomic-embed-text`. They are not transferable to other embedding models. The threshold used in these experiments (0.78) is directional, not an optimal value.

One design decision worth noting: short, templated query strings ("Service: X. Exception: Y") collapsed to identical embeddings regardless of the exception name — `nomic-embed-text` couldn't differentiate them. The fix was richer query text: splitting CamelCase exception names into words for semantic signal, adding the `search_query:`/`search_document:` prefixes the model was trained with, and including finding content in stored embeddings. After that, the model separated genuinely unrelated incidents (different services, different error domains) into the 0.61–0.67 range, same-service-different-bug into 0.74–0.78, and real matches into 0.80–0.81. Enough spread for a meaningful threshold.

### Where it wins: drift

The canonical incident fingerprints as `ecommerce-api|StockMismatchError` (hash `e2836e74`). Imagine the exception class gets renamed to `InventoryValidationError` in a refactor. The new fingerprint hashes to `de61efe2` — a completely different hash. Exact lookup misses. The TOCTOU finding sits in memory, unreachable.

Similarity search finds it at 0.81. The agent loaded the finding, confirmed the race was present in the live code, and proposed the correct mutex fix. This is similarity earning its place — semantic closeness rescuing a lookup that string identity lost.

## The wall

Here is the full retrieval table, computed deterministically from the embeddings:

| Incident | Hash | Exact | Sim 0.68 | 0.74 | 0.76 | 0.78 | 0.80 | 0.84 | Score |
|---|---|---|---|---|---|---|---|---|---|
| Canonical | e2836e74 | HIT | HIT | HIT | HIT | HIT | miss | miss | 0.798 |
| Drift | de61efe2 | miss | HIT | HIT | HIT | HIT | HIT | miss | 0.809 |
| Near-miss | e2836e74 | HIT | HIT | HIT | HIT | HIT | miss | miss | 0.798 |
| No-precedent | 2c8fc300 | miss | HIT | HIT | miss | miss | miss | miss | 0.742 |

The canonical and the near-miss score identically: **0.798**. No threshold separates them — any threshold that admits the canonical also admits the near-miss; any threshold that blocks the near-miss also blocks the canonical. Retrieval tuning is powerless here by construction. The dangerous case and the safe case are the same number.

The near-miss incident runs `inventory-nearmiss.js`, which layers a stale-read cache (5-second TTL, never invalidated on write) on top of the same TOCTOU race present in the canonical `inventory.js`. The recalled finding — describing the TOCTOU race and recommending a per-product mutex — is genuinely partly right for this incident. A mutex would help. But the cache is a distinct failure mechanism that the mutex alone doesn't fix, and without discipline, the agent stops at what memory tells it.

## The lever that works

The retrieval layer can't distinguish the near-miss. The question is whether the agent, given the recalled finding, can. `watcher-semantic-example/` adds a second toggle: `validation_discipline: true | false`. When on, Phase 1's prompt requires the agent to explicitly classify the recalled finding as VALIDATED, INVALIDATED, or INCONCLUSIVE against current evidence before proceeding. When off, the finding is provided as context with no forced classification step.

I ran the near-miss incident through both configurations, 4 times each (1 original + 3 replication runs), holding everything else fixed: same model (Sonnet 4.6), same threshold (0.78), same recalled TOCTOU finding, same cluster running the cache-plus-race variant.

### The tally

| | Runs | CAUGHT | ANCHORED |
|---|---|---|---|
| **Discipline OFF** | 4 | 1 | 3 |
| **Discipline ON** | 4 | 4 | 0 |

CAUGHT: Phase 1 identified the cache as a distinct root cause. Phase 2 fix included cache invalidation (`delete stockCache[item.id]` or equivalent).

ANCHORED: Phase 1 framed the cache as secondary to the race. Phase 2 fix was race-only — a re-read before decrement or mutex, with no cache invalidation.

n=8 total. This is "shifted the dominant mode from 1-in-4 to 4-for-4 across our runs," not "always works." Small n, clear direction, replicated.

### The mechanism: forced corroboration, not rejection

The critical detail: 3 of the 4 discipline-ON runs classified the recalled finding as **VALIDATED**. Only one said INVALIDATED. All four reached the cache diagnosis. The discipline didn't work by rejecting the recalled finding — it worked by requiring the agent to corroborate the finding against fresh evidence, which forced it to investigate deeply enough to discover the cache layer that the recalled TOCTOU finding didn't mention.

The verbatim classifications from the four discipline-ON runs (one per run, from the audit logs):

> **Validation: VALIDATED** — Prior finding (TOCTOU race in `reserveInventory()`) is confirmed by fresh evidence. Product 7 stock at -3 in 1,444 error messages proves concurrent decrements past zero. **New finding:** the pod is running `inventory-nearmiss.js` via `nearmiss-loader.js`, which adds a 5-second read-through cache absent from the prior finding.

> **Validation: VALIDATED** — prior finding matches current evidence because the same TOCTOU race in `reserveInventory()` is present and active. However, the pod is running a new variant (`inventory-nearmiss.js`) not described in the prior finding.

> **Validation: VALIDATED** — prior finding matches current evidence. The TOCTOU race in `reserveInventory()` is active and confirmed. The nearmiss variant extends the prior finding with a new amplification layer.

> **Validation: INVALIDATED** — prior finding does NOT match current evidence. Investigating from the new runtime state.

The label varied. The depth didn't. The forced classification step is a corroboration trigger — it doesn't matter whether the agent says "matches" or "doesn't match," because either answer requires it to examine the current evidence closely enough to notice what the recalled finding left out. The verdict is a side effect; the investigation is the mechanism.

### The honest wrinkle

One discipline-OFF run (off-r3) caught the cache without prompting. The model identified "two co-root-causes" and included cache invalidation in its fix. So the capability exists unprompted — the base rate is 25% (1 of 4). Discipline is a reliability intervention, not a capability one. The model can find the cache on its own; it just usually doesn't bother when a plausible answer (the TOCTOU race from memory) is already in front of it.

## Memory poisoning and un-poisoning

There's a secondary effect worth tracking. Each run writes its findings back to `e2836e74.md` at the end of Phase 2.

The undisciplined runs that anchored on the TOCTOU race wrote the race-only diagnosis back to memory. The memory store after an anchored run contains no mention of the cache — the correct diagnosis from the Post 10 cold run is overwritten. The next incident with this fingerprint will load the race-only finding, making it even more likely the agent anchors again. Misdirection compounds.

The disciplined runs that caught the cache wrote the cache diagnosis back. One run's memory write-back read: "5-second read-through cache never invalidated after write... evict the cache entry immediately after the inventory decrement." The correct finding replaced the incomplete one. Discipline doesn't just fix this incident — it fixes what propagates forward.

## The cost table

Included because the data exists, not because the numbers mean anything at n=4.

| Config | P1 turns (median) | P2 turns (median) | Total cost (median) |
|---|---|---|---|
| Discipline OFF | 17.5 | 13.5 | $0.46 |
| Discipline ON | 19.5 | 13.0 | $0.53 |

The discipline runs cost marginally more (~15%), driven partly by one ON run (on-r3) that classified the finding as INVALIDATED and ran a 33-turn from-scratch investigation. Do not interpret this as a performance finding — it's 4 runs on one incident type, not a benchmark.

## What this means

Similarity retrieval genuinely helps the drift case. A renamed exception that exact-hash can't reach, similarity finds at 0.81. That's real value — the watcher can now recall findings across signature changes, which is the common case when code gets refactored between incidents.

But retrieval quality was never the bottleneck for the dangerous case. The near-miss scores identically to the true match. No embedding model, no threshold sweep, no retrieval architecture can separate 0.798 from 0.798. The wall is in the numbers.

The lever that gets past the wall is a reasoning discipline: a prompt-level requirement to classify a recalled finding against current evidence before using it. It costs one extra prompt section. It turned 1-in-4 into 4-for-4 across our runs by forcing corroboration deep enough to find what the recalled finding missed. It un-poisons the memory store by writing back the correct diagnosis. And its mechanism — forced depth, not forced rejection — is the right one for production, where recalled findings are usually partially right, not completely wrong.

The memory store is only as good as the discipline with which the agent treats what it recalls. Retrieval puts the finding in front of the agent; the discipline determines whether the agent stops there or keeps looking. That's the Part 3 reframe — and that's what [Post 9](09-context-engineering-for-ai-sre.md) makes precise.

The reference implementation is in [`watcher-semantic-example/`](https://github.com/har-ki/claude-code-sre-handbook/tree/main/watcher-semantic-example). Three config knobs, no code changes between runs.

---

*Working through this on your own infrastructure? Happy to jam — [drop me a line](https://github.com/har-ki).*
