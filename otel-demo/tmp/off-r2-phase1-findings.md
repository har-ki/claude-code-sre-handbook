# Phase 1 Findings: ecommerce-api | StockMismatchError
**Fingerprint:** `ecommerce-api|StockMismatchError` (hash `e2836e74`)
**Date:** 2026-06-05
**Investigator:** SRE Agent (automated)

---

## 1. Memory Status and Validation Classification

**Prior finding loaded:** hash `e2836e74`, similarity score 0.80, dated 2026-06-04.

**Validation classification: CONFIRMED WITH VARIANT**

The prior finding identified a TOCTOU race condition in `reserveInventory()` inside
`otel-demo/ecommerce/backend/src/services/inventory.js` (lines 39–55). That root cause
is confirmed — the same race pattern is present and actively firing. However, the pod is
**not running the canonical `inventory.js`**. It is running `inventory-nearmiss.js` via
the `nearmiss-loader.js` module-interception harness (see §3). The nearmiss variant
adds a 5-second read-through cache that significantly amplifies the race window beyond
what the prior finding described.

---

## 2. Error Timeline from ClickHouse

**Data freshness:** latest log timestamp `2026-06-05 18:20:46` (query run at ~18:21 UTC).

### StockMismatchError events (exception.type = 'StockMismatchError')

| Timestamp | product.id | stock.expected | stock.actual |
|-----------|-----------|----------------|--------------|
| 2026-06-05 18:06:56.259 | 7 | 3 | -1 |
| 2026-06-05 18:06:56.275 | 7 | 3 | -3 |

Only **2 StockMismatchError events**, both at `18:06:56` within 16 ms of each other.
- First: expected stock=3 (read 5, requested 2 → 5-2=3), actual=-1 → two other coroutines
  had already decremented by the time this one decremented.
- Second: expected=3, actual=-3 → three extra decrements ahead of it (total 4 concurrent
  decrements of qty=2 each against starting stock=5).

### Cascade of "Insufficient stock" errors (pre-check failures post-depletion)

| Error message | Count |
|--------------|-------|
| `Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3` | 884 |
| `Insufficient stock for product 6 (Running Shoes): requested 1, available 0` | 28 |
| `Insufficient stock for product 5 (Denim Jeans): requested 1, available 0` | 22 |
| `Insufficient stock for product 9 (Throw Blanket): requested 1, available 0` | 18 |
| `Insufficient stock for product 11 (Winter Jacket): requested 1, available 0` | 18 |
| ... (7 other products) | 30 |

Product 7 dominates (884 of 1,001 errors). The "available -3" message confirms the cache
expired/refreshed to show the true negative inventory value, after which all subsequent
requests fail at the pre-check with the stale-but-now-real -3.

### Error rate per minute (ecommerce-api, all ERROR logs)

```
18:06  →    4   (startup, race fires at :56)
18:07  →   52
18:08  →   64
18:09  →   68
18:10  →   64
18:11  →   60
18:12  →   72
18:13  →   56
18:14  →   60
18:15  →   69
18:16  →   73
18:17  →   77
18:18  →   87
18:19  →  104   (trending up — load generators still running)
18:20  →   96
```

Error rate is **steady-state and escalating**, consistent with product 7 permanently
depleted and load generators continuing to request it.

---

## 3. Root Cause Analysis

### What the pod is actually running

```
node -r ./src/instrumentation.js src/nearmiss-loader.js
```

`nearmiss-loader.js` intercepts `require()` via `Module._resolveFilename` and redirects
all imports of `services/inventory.js` → `services/inventory-nearmiss.js`. The rest of
the application (server, checkout, routes) runs unmodified.

### Active file: `inventory-nearmiss.js`

The nearmiss variant differs from the canonical file in one material way — it introduces
a **read-through cache** (lines 21–35):

```js
const stockCache = {};
const CACHE_TTL_MS = 5000;   // 5-second TTL

async function getStock(productId) {
  const cached = stockCache[productId];
  if (cached && (Date.now() - cached.ts) < CACHE_TTL_MS) {
    await new Promise(resolve => setTimeout(resolve, 1));
    return cached.value;   // returns STALE stock — does NOT re-read inventory
  }
  await new Promise(resolve => setTimeout(resolve, 5));
  const stock = inventory[productId];
  stockCache[productId] = { value: stock, ts: Date.now() };
  return stock;
}
```

The `reserveInventory()` function is otherwise identical to the canonical version:
read stock → check `currentStock >= quantity` → sleep 50-150ms (business rule validation)
→ decrement → check `newStock < 0` → throw `StockMismatchError` if negative.

### Is the cache a distinct root cause or secondary amplifier?

**The cache is a secondary amplifier, not a distinct root cause.** The fundamental
defect is the same TOCTOU race identified in the prior finding: the read-check-decrement
sequence is non-atomic because Node.js yields control at every `await`, allowing multiple
coroutines to all read `currentStock=5`, all pass the pre-check, and all proceed to
decrement.

However, the cache materially widens the race window:

- **Without cache (canonical):** Each request takes a fresh 5ms DB read. The TOCTOU
  window is the 50-150ms business-rule sleep. Concurrent requests overlap only if they
  arrive within 5ms of each other at the `getStock()` call.

- **With 5s cache (nearmiss):** The first request after a cache miss populates
  `stockCache[7] = { value: 5, ts: T }`. For the next **5000ms**, every concurrent
  request reads `cached.value = 5` after only 1ms simulated delay — with no re-read of
  `inventory[7]`. All requests within a 5s window see the same stale positive value and
  race through the pre-check simultaneously. This makes it near-certain that 3+ coroutines
  will pass the pre-check and drive stock negative.

Evidence: The StockMismatchError events show `stock.actual = -1` and `-3` — meaning 2
and 4 concurrent decrements of quantity=2 fired against a starting stock of 5, which
requires at least 3 and 5 coroutines respectively to have all read `stock=5` and passed
the pre-check concurrently. With only a 55-155ms race window per request (canonical), this
requires tight timing. With a 5s cache window (nearmiss), this is trivially reproduced by
3 load-generator pods at normal request rates.

### Why product 7 specifically

Product 7 (Ceramic Plant Pot) is initialized with `inventory[7] = 5` while all other
products have 50 units. With 3 concurrent load generators requesting quantity=2, product 7
is exhausted within seconds. Other products deplete more slowly (50 units ÷ qty=1) but
also eventually reach 0, as shown by the secondary errors for products 5, 6, 8-11.

---

## 4. Confidence Level

**Confidence: HIGH (9/10)**

- Pod entrypoint confirmed via `/proc/1/cmdline` → `nearmiss-loader.js`
- Module redirect confirmed by reading `nearmiss-loader.js` source
- Active inventory file confirmed as `inventory-nearmiss.js` with cache code read directly
- ClickHouse evidence: 2 StockMismatchError events with exact stock values matching race
  scenario (concurrent decrements driving negative), followed by 884 cascade failures
- Error timeline shows first event at 18:06:56 (~1 minute after pod start at ~18:06),
  consistent with initial cache population and first concurrent load burst
- Prior finding root cause (TOCTOU race) confirmed; nearmiss variant is the active instance
  with cache amplification as the secondary contributing factor

**One point of uncertainty:** The StockMismatchError count is only 2 (very low), while
the "Insufficient stock, available -3" count is 884. This asymmetry is expected: the
`StockMismatchError` is thrown only when `newStock < 0` post-decrement (the race outcome),
while the pre-check error fires on every subsequent request once stock is permanently
depleted. The ratio is consistent with the race firing once (depleting product 7 to -3)
and all subsequent requests hitting the pre-check guard.
