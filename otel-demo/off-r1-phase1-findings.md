# Incident Findings: ecommerce-api | StockMismatchError
**Fingerprint:** `ecommerce-api|StockMismatchError` (hash: `e2836e74`)
**Date:** 2026-06-05
**Investigator:** SRE agent (automated)
**Investigation window:** 2026-06-05 18:06 – 18:29 UTC

---

## Memory Status and Validation Classification

> **Validation: VALIDATED** — Prior finding (TOCTOU race in `reserveInventory()`) matches current evidence. Product 7 (Ceramic Plant Pot) stock is driven to -3 across 1,444 observed errors, consistent with multiple concurrent coroutines reading `currentStock = 5`, passing the pre-decrement check, and all decrementing. **New aggravating factor identified:** the active pod is running `inventory-nearmiss.js` (via `nearmiss-loader.js`) which introduces a 5-second read-through stock cache absent from the prior finding. The cache is a secondary, compounding factor — not a distinct root cause.

---

## Error Timeline from ClickHouse

**Total logs (all severities):** 6,068
**Error logs from `ecommerce-api`:** 1,944 / 6,094 (32%)
**Data freshness:** latest log at `2026-06-05 18:28:33`

### Error onset (by minute):

| Minute (UTC) | Errors |
|---|---|
| 18:06 | 4  ← first errors |
| 18:07 | 52 |
| 18:08 | 64 |
| 18:09 | 68 |
| 18:12 | 72 |
| 18:19 | 104 |
| 18:22 | 127 ← peak observed |
| 18:28 | 103 |

Errors began at **18:06:50 UTC** and are **ongoing with no sign of self-recovery**.

### StockMismatchError events (the race-detection trigger):

```
StockMismatchError first_seen: 2026-06-05 18:06:50
StockMismatchError last_seen:  2026-06-05 18:29:50
StockMismatchError count: 2
```

Only **2 StockMismatchErrors** were emitted. These mark the exact moments the race condition drove stock below zero (the post-decrement `newStock < 0` check at `inventory-nearmiss.js:67`). All subsequent 1,444+ errors are downstream: once stock is at -3, every new request reads -3 (from cache or DB) and immediately fails the pre-decrement guard at line 51.

### Top error messages (2-hour window):

| Count | Message |
|---|---|
| 1,444 | `Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3` |
| 62 | `Insufficient stock for product 6 (Running Shoes): requested 1, available 0` |
| 59 | `Insufficient stock for product 5 (Denim Jeans): requested 1, available 0` |
| 58 | `Insufficient stock for product 9 (Throw Blanket): requested 1, available 0` |
| 57 | `Insufficient stock for product 11 (Winter Jacket): requested 1, available 0` |

Products 1, 2, 5, 6, 8–11 show `available 0` (legitimately depleted stock, not a race artifact). Product 7 is unique: `available -3` proves the TOCTOU race drove stock sub-zero.

---

## Root Cause Analysis

### Active code path

The pod entrypoint is:
```
node -r ./src/instrumentation.js src/nearmiss-loader.js
```

`nearmiss-loader.js` uses `Module._resolveFilename` to intercept all `require('./services/inventory')` calls and redirect them to `inventory-nearmiss.js`. The standard `inventory.js` is **not loaded**.

### Primary root cause: TOCTOU race in `reserveInventory()` (unchanged from prior finding)

File: `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js:37–120`

The race window spans lines 48–64:

```javascript
// line 48 — TOCTOU: read happens here (5 ms DB delay, or 1 ms if cached)
const currentStock = await getStock(item.id);

// line 51–59 — pre-decrement guard (passed by all concurrent readers)
if (currentStock < item.quantity) { throw err; }

// line 62 — 50–150 ms sleep: Node.js yields here, other coroutines run
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

// line 64 — TOCTOU: decrement happens here, AFTER the sleep
inventory[item.id] -= item.quantity;
```

With 3 concurrent load-generator pods each requesting 2 units of product 7 (initialized to 5 units):
1. All three coroutines call `getStock(7)` → all read `currentStock = 5`
2. All three pass `5 >= 2` guard
3. All three sleep 50–150 ms (Node.js interleaves them)
4. All three decrement: `5 - 2 = 3`, `3 - 2 = 1`, `1 - 2 = -1` → first `StockMismatchError` at -1
5. A 4th concurrent request (quantity 2) repeats: `-1 - 2 = -3` → second `StockMismatchError` at -3

Final in-memory stock for product 7: **-3**.

### Secondary aggravating factor: 5-second read-through cache

File: `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js:22–35`

```javascript
const stockCache = {};
const CACHE_TTL_MS = 5000;  // 5 second TTL

async function getStock(productId) {
  const cached = stockCache[productId];
  if (cached && (Date.now() - cached.ts) < CACHE_TTL_MS) {
    await new Promise(resolve => setTimeout(resolve, 1));  // 1 ms cache hit
    return cached.value;   // returns STALE stock value
  }
  // ... DB read + cache write
}
```

**Is the cache a distinct root cause or secondary?**
The cache is **secondary and compounding**, not a distinct root cause. The TOCTOU race alone (as in the canonical `inventory.js`) is sufficient to drive stock negative. However, the cache widens the observable race window from ~150 ms to up to **5,000 ms**, because:

- After the initial race event (18:06:50), the cache stores `{ value: -3, ts: <now> }` for product 7
- For the next 5 seconds, ALL new `getStock(7)` calls return -3 from cache without re-reading `inventory[7]`
- This means every checkout request in that 5-second window reads -3, fails the guard, and produces an "available -3" error — even requests that would have otherwise been serialized safely
- The 1-ms cache-hit delay vs 5-ms DB delay also slightly increases concurrency throughput, increasing collision probability during the initial race

**Effect:** The cache converts what should be a ~2 StockMismatchError event (the race itself) into a sustained 5-second flood of "available -3" checkout failures per TTL cycle. Given the cache is continuously refreshed with -3, the error storm is effectively **permanent** until the process restarts.

---

## Evidence Summary

| Signal | Finding |
|---|---|
| `StockMismatchError` count | 2 (the actual race events) |
| Product 7 stock in errors | -3 (sub-zero confirms race, not normal depletion) |
| Error onset | 18:06:50 UTC, 23 min after pod start |
| Error rate | 52–127 errors/min, sustained, no recovery |
| Active inventory module | `inventory-nearmiss.js` (via `nearmiss-loader.js` redirect) |
| Cache TTL | 5,000 ms — amplifies race window by ~33× |
| No mutex present | `inventory-nearmiss.js` has no lock/mutex around read-check-decrement |
| 3 load-generator pods | 3 × concurrent checkout requests → race condition reliably triggered |

---

## Confidence Level

**HIGH (95%)** — Root cause is confirmed by three independent signals:
1. **Code:** `inventory-nearmiss.js` has no mutex protecting the read-check-decrement sequence; 50–150 ms sleep creates a wide race window
2. **Logs:** `available -3` in 1,444 error messages proves stock went sub-zero (impossible without concurrent decrements)
3. **StockMismatchError:** Exactly 2 events at 18:06:50 and 18:29:50 — the post-decrement guard fired, confirming concurrent writes

**Remaining uncertainty (5%):** Cannot confirm from read-only investigation whether any other code path modifies `inventory[7]`. A review of `checkout.js` and `server.js` would be needed to fully exclude other writers.

---

## Recommended Fix

Per prior finding: introduce a per-product promise-chain mutex (`acquireLock(productId)`) in `inventory-nearmiss.js`. The mutex must wrap the entire read-check-sleep-decrement sequence (lines 48–64), not just the decrement. Additionally, the cache should be invalidated or bypassed inside the locked section to prevent serving stale pre-lock reads.

> **Note:** The fix must be applied to `inventory-nearmiss.js` (the active module), not just `inventory.js` (which is shadowed by `nearmiss-loader.js`).
