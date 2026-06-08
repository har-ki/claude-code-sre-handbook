# Phase 1 Investigation Findings — ecommerce-api StockMismatchError

**Fingerprint:** `ecommerce-api|StockMismatchError` (`e2836e74`)
**Date:** 2026-06-04
**Investigator:** SRE Agent (automated)

> **Memory:** No prior finding for fingerprint e2836e74

---

## Memory Status

**MISS** — No prior finding for fingerprint `e2836e74`. Fresh investigation performed.

---

## Pod Health

```
NAME                            READY   STATUS    RESTARTS   AGE
ecommerce-api-57db6bbd9-tcwxw   1/1     Running   0          20m
load-generator-9c744b49-mt48z   1/1     Running   2          20m
load-generator-9c744b49-v4khw   1/1     Running   0          20m
load-generator-9c744b49-x9jjz   1/1     Running   0          20m
```

Pod is healthy — no crashes or restarts on the API pod. Errors are logical (race condition), not infrastructure failures.

---

## Error Timeline (last 15 minutes)

| Minute (UTC) | Total Errors | StockMismatchError |
|---|---|---|
| 19:35 | 60 | 0 |
| 19:36 | 64 | 0 |
| 19:37 | 56 | 0 |
| 19:38 | 64 | 0 |
| 19:39 | 80 | **2** |
| 19:40 | 85 | **2** |
| 19:41 | 95 | 0 |
| 19:42 | 107 | 0 |
| 19:43 | 106 | 0 |
| 19:44 | 117 | **1** |
| 19:45 | 124 | 0 |
| 19:46 | 119 | 0 |
| 19:47 | 119 | 0 |
| 19:48 | 123 | 0 |
| 19:49 | 106 | 0 |

- **~1,400 total errors** in 15 minutes (~93/min), rising trend.
- **StockMismatchError** (stock goes negative after decrement) is sporadic but real — 5 occurrences in sample window.
- The bulk of errors are `Insufficient stock` (TOCTOU check failures) not the negative-stock variant — but both stem from the same root cause.

### Top Error Messages (ClickHouse, last 15 min)

| Exception Message | Count |
|---|---|
| Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 | **996** |
| Insufficient stock for product 1 (Wireless Headphones): requested 1, available -1 | 47 |
| Insufficient stock for product 8 (LED Desk Lamp): requested 1, available 0 | 47 |
| Insufficient stock for product 12 (Coffee Maker): requested 1, available 0 | 46 |
| Insufficient stock for product 5 (Denim Jeans): requested 1, available -1 | 44 |
| Inventory inconsistency: stock for product 6 (Running Shoes) is -2 after decrement (was 1 at read time) | 1 |
| StockMismatchError: stock for product 6 (Running Shoes) is -1 after decrement (was 1 at read time) | 1 |
| StockMismatchError: stock for product 9 (Throw Blanket) is -1 after decrement (was 1 at read time) | 1 |
| StockMismatchError: stock for product 1 (Wireless Headphones) is -2 after decrement (was 2 at read time) | 1 |

**Product 7 (Ceramic Plant Pot)** dominates with 996 errors — it has only 5 units initial stock, making it deplete fastest.

---

## Root Cause Analysis

### The Actual Module Running in the Pod

The pod runs:
```
node -r ./src/instrumentation.js src/nearmiss-loader.js
```

`nearmiss-loader.js` patches Node.js's `Module._resolveFilename` at startup to intercept all `require('./services/inventory')` calls and silently redirect them to `services/inventory-nearmiss.js` instead of the canonical `services/inventory.js`.

```js
// nearmiss-loader.js:16-23
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  const resolved = origResolve.call(this, request, parent, isMain, options);
  if (resolved === canonicalPath) {
    return nearmissPath;   // ← silently swaps inventory.js → inventory-nearmiss.js
  }
  return resolved;
};
```

Despite `checkout.js:5` importing `require('../services/inventory')`, the pod is actually running `inventory-nearmiss.js`.

### The Race Condition (TOCTOU)

The difference between the canonical and near-miss inventory modules is in `getStock()`:

**Canonical `inventory.js:22-25`** — direct read, no caching:
```js
async function getStock(productId) {
  await new Promise(resolve => setTimeout(resolve, 5));
  return inventory[productId];   // always current
}
```

**Near-miss `inventory-nearmiss.js:25-35`** — read-through cache with 5-second TTL:
```js
async function getStock(productId) {
  const cached = stockCache[productId];
  if (cached && (Date.now() - cached.ts) < CACHE_TTL_MS) {  // TTL = 5000ms
    await new Promise(resolve => setTimeout(resolve, 1));
    return cached.value;   // ← STALE VALUE
  }
  await new Promise(resolve => setTimeout(resolve, 5));
  const stock = inventory[productId];
  stockCache[productId] = { value: stock, ts: Date.now() };
  return stock;
}
```

### Exact Race Sequence

The `reserveInventory` function (`inventory-nearmiss.js:38-120`) has a **read-check-delay-write** pattern with no locking:

```
Step 1 (line 48):  currentStock = await getStock(item.id)   ← returns CACHED value
Step 2 (line 51):  if (currentStock < item.quantity) throw  ← check passes on stale value
Step 3 (line 62):  await sleep(50 + random * 100)           ← 50–150ms window wide open
Step 4 (line 64):  inventory[item.id] -= item.quantity       ← unsynchronized write
Step 5 (line 67):  if (newStock < 0) throw StockMismatchError
```

**Race timeline for product 7 (Ceramic Plant Pot, stock=1):**

```
T=0ms    Request A: getStock(7) → cache miss → reads inventory[7]=1, caches it
T=1ms    Request B: getStock(7) → cache HIT → returns cached value 1
T=2ms    Request C: getStock(7) → cache HIT → returns cached value 1
T=3ms    Request D: getStock(7) → cache HIT → returns cached value 1
         All pass the "currentStock < quantity" check (1 >= 1 ✓)
T=50ms   All 4 requests enter the sleep(50–150ms) window concurrently
T=100ms  Request A completes: inventory[7] = 1 - 1 = 0
T=110ms  Request B completes: inventory[7] = 0 - 1 = -1  ← StockMismatchError
T=120ms  Request C completes: inventory[7] = -1 - 1 = -2 ← StockMismatchError
T=130ms  Request D completes: inventory[7] = -2 - 1 = -3 ← "available -3" in logs
```

This exactly matches the log evidence: `"available -3"` for product 7 with 996 occurrences.

### Why The Cache Makes It Worse

Without caching, each request would read the live `inventory` value. Under high concurrency, JavaScript's single-threaded event loop means only one synchronous operation runs at a time — the 5ms async delay is a yield point, but reads of `inventory[id]` happen synchronously after the await resolves. The cache extends the stale-read window from the duration of one request to 5,000ms, allowing hundreds of requests to read the same stale stock value before any decrement is visible.

---

## Confidence Level

**HIGH**

Evidence chain is complete:
1. Pod startup command confirmed: `nearmiss-loader.js` is the entry point
2. Module patching confirmed: `nearmiss-loader.js` redirects `inventory.js` → `inventory-nearmiss.js`
3. Cache behavior confirmed in source: 5-second TTL at `inventory-nearmiss.js:23`
4. Race window confirmed: 50–150ms artificial delay at `inventory-nearmiss.js:62`
5. No atomic check-and-decrement — unsynchronized read-modify-write at lines 48→62→64
6. Log evidence matches: product 7 (lowest stock=5) has 996 errors; negative stock values (-3) match multiple concurrent decrements

---

## Remediation (read-only finding — not applied)

1. **Immediate:** Remove the `nearmiss-loader.js` entry point; deploy with `node -r ./src/instrumentation.js src/server.js` to use the canonical (non-caching) inventory module.
2. **Fix the race:** Replace the read-check-write pattern with an atomic compare-and-swap or use a mutex around the read/decrement block.
3. **If cache is retained:** Cache must be invalidated on every write, and the check-then-decrement must be done under a lock.
4. **Long-term:** Move inventory to a real database with `UPDATE inventory SET stock = stock - ? WHERE product_id = ? AND stock >= ?` — let the DB enforce atomicity.
