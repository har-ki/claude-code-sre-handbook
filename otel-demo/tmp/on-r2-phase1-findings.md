# Phase 1 Findings: ecommerce-api | StockMismatchError
**Fingerprint:** `ecommerce-api|StockMismatchError` (hash `e2836e74`)
**Date:** 2026-06-05
**Investigator:** SRE Agent (automated)

---

## 1. Memory Status and Validation Classification

**Prior finding loaded:** hash `e2836e74`, similarity score 0.80, dated 2026-06-04.

> **Validation: VALIDATED** — prior finding matches current evidence because the same TOCTOU race condition in `reserveInventory()` (read-check-sleep-decrement) is present and actively firing in the running code. However, the pod is running `inventory-nearmiss.js` (not the canonical `inventory.js`), which adds a 5-second read-through cache that amplifies the race window beyond what the prior finding described. The core defect is confirmed; the deployment variant is new.

---

## 2. Error Timeline from ClickHouse

**Query window:** `now() - INTERVAL 2 HOUR` (run at ~18:32 UTC 2026-06-05)

### StockMismatchError events (exception.type = 'StockMismatchError')

| Timestamp (UTC) | product.id | stock.actual |
|----------------|-----------|--------------|
| 2026-06-05 18:06 | 7 | -1 |
| 2026-06-05 18:06 | 7 | -3 |

Only **2 StockMismatchError events** in the 2-hour window, both within the same minute:
- `stock.actual = -1`: two extra concurrent decrements of qty=2 fired (total 3 coroutines against stock=5 → 5-6=-1)
- `stock.actual = -3`: four extra concurrent decrements fired (total 5 coroutines → 5-10=-5... the -3 indicates partial ordering of 4 concurrent decrements: net 5 - 2×4 = -3)

### Cascade of "Checkout failed" (pre-check failures post-depletion)

Representative sample from 20 most recent errors (18:32 UTC):

```
Checkout failed: order=ORD-EA17746D — Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3
Checkout failed: order=ORD-051FDF7D — Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3
Checkout failed: order=ORD-BE2F90C6 — Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3
Checkout failed: order=ORD-88912BA2 — Insufficient stock for product 9 (Throw Blanket): requested 1, available 0
Checkout failed: order=ORD-7E3904C9 — Insufficient stock for product 1 (Wireless Headphones): requested 1, available 0
Checkout failed: order=ORD-8EB856CF — Insufficient stock for product 8 (LED Desk Lamp): requested 1, available 0
```

Product 7 dominates the error stream. Multiple other products (1, 8, 9, 10) also fully depleted.
The "available -3" value persisted in the cache TTL window, then became a permanent pre-check rejection.

---

## 3. Root Cause Analysis

### Pod entrypoint (what is actually running)

From `kubectl describe pod -l app=ecommerce-api -n ecommerce`:
```
Command: node -r ./src/instrumentation.js src/nearmiss-loader.js
Environment: INVENTORY_VARIANT=nearmiss
```

`nearmiss-loader.js` intercepts Node.js's `Module._resolveFilename` and redirects all
`require()` calls for `services/inventory.js` → `services/inventory-nearmiss.js`:

```js
// nearmiss-loader.js lines 13-23
const canonicalPath = path.resolve(__dirname, 'services', 'inventory.js');
const nearmissPath  = path.resolve(__dirname, 'services', 'inventory-nearmiss.js');

Module._resolveFilename = function (request, parent, isMain, options) {
  const resolved = origResolve.call(this, request, parent, isMain, options);
  if (resolved === canonicalPath) return nearmissPath;
  return resolved;
};
```

### Active defect: TOCTOU race + cache amplification

**File:** `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js`

The nearmiss variant adds a read-through cache absent from the canonical file:

```js
// inventory-nearmiss.js lines 22-35
const stockCache = {};
const CACHE_TTL_MS = 5000;  // 5-second TTL

async function getStock(productId) {
  const cached = stockCache[productId];
  if (cached && (Date.now() - cached.ts) < CACHE_TTL_MS) {
    await new Promise(resolve => setTimeout(resolve, 1));  // 1ms simulated
    return cached.value;  // STALE value — does NOT re-read inventory[]
  }
  await new Promise(resolve => setTimeout(resolve, 5));
  const stock = inventory[productId];
  stockCache[productId] = { value: stock, ts: Date.now() };
  return stock;
}
```

`reserveInventory()` (lines 38-120) is then structurally identical to the canonical:

```
1. await getStock(item.id)          ← reads cache (stale) or inventory (fresh)
2. if (currentStock < item.quantity) throw                ← pre-check
3. await sleep(50 + random*100 ms)  ← TOCTOU window: business rule validation
4. inventory[item.id] -= item.quantity                    ← decrement
5. if (newStock < 0) throw StockMismatchError             ← post-decrement guard
```

### Is the cache a distinct root cause or secondary amplifier?

**The cache is a secondary amplifier — not a distinct root cause.**

The fundamental defect is the same TOCTOU race from the prior finding:
- Node.js yields control at every `await`
- Multiple coroutines can all read `currentStock=5`, all pass step 2, then all decrement in step 4
- The 50-150ms sleep at step 3 is the primary race window

The cache worsens the race in two ways:

1. **Widens the stale read window from 5ms to 5000ms.** Without the cache, each request
   takes a fresh 5ms DB read that reflects the current `inventory[id]` value. With the
   cache, after the first cache miss, every request within a 5-second window reads
   `cached.value = 5` (the pre-depletion value) after only 1ms delay — regardless of
   whether previous coroutines have already decremented `inventory[7]`.

2. **Guarantees all concurrent requests see the same stale stock.** With 3 load-generator
   pods at normal throughput, multiple requests for product 7 will arrive within the
   5s TTL window, all reading `5` from cache, all passing the pre-check, all proceeding
   to decrement. This makes the race near-certain rather than probabilistic.

Evidence: `stock.actual = -3` requires at least 4 concurrent decrements of qty=2 against
starting stock=5 (5 - 2×4 = -3). With a 155ms max per-request race window (canonical),
this would require 4 requests to arrive within 155ms — tight but possible. With a 5s
cache window, any 4 requests within 5 seconds will all see `stock=5` and race — trivially
reproduced by 3 pods at normal load.

### Why product 7 specifically

`inventory[7] = 5` (Ceramic Plant Pot) while all other products initialize at 50.
With 3 load generators requesting qty=2, product 7 exhausts in a single cache TTL window.
Other products (50 units, qty=1) deplete more slowly but also eventually reach 0.

---

## 4. Confidence Level

**Confidence: HIGH (9/10)**

Supporting evidence:
- Pod command confirmed via `kubectl describe`: running `nearmiss-loader.js`
- Module redirect confirmed by reading `nearmiss-loader.js` source (lines 13-23)
- Active inventory file confirmed as `inventory-nearmiss.js` — cache code read directly (lines 22-35)
- ClickHouse: 2 `StockMismatchError` events with `stock.actual` values of -1 and -3, consistent with 3 and 5 concurrent decrements respectively
- Cascade of checkout failures at "available -3" confirms race fired exactly once and permanently depleted product 7
- Error timeline: first event at 18:06 (~1 min after pod start), consistent with initial cache population + first concurrent burst
- Prior finding root cause (TOCTOU race) confirmed present in nearmiss variant; cache is the novel amplifier

One point of uncertainty (1 point deducted): only 2 StockMismatchErrors were captured
in ClickHouse. The `stock.actual = -3` would require 5 concurrent decrements of qty=2
(net: 5 - 10 = -5, but the decrement order matters — actual result -3 implies 4
concurrent decrements landed before the check, or partial interleaving). The exact
concurrent count is not directly observable from logs alone.
