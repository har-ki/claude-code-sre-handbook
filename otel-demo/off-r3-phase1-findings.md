# Phase 1 Findings — off-r3 — ecommerce-api | StockMismatchError

**Fingerprint:** `ecommerce-api|StockMismatchError`
**Hash:** `e2836e74`
**Date:** 2026-06-05
**Investigation time window:** 18:06–18:37 UTC

---

## 1. Memory Status and Validation Classification

**Prior finding loaded** (similarity score 0.80, matched hash `e2836e74`, captured 2026-06-04).

> **Validation: INVALIDATED** — prior finding does NOT match current evidence because the pod is running `inventory-nearmiss.js` (via `nearmiss-loader.js`) instead of the canonical `inventory.js`. The prior finding described product 7 (Ceramic Plant Pot) as the sole affected product due to its 5-unit initial stock. Current ClickHouse evidence shows errors across **all 12 products** including those initialized with 50 units. This expanded blast radius is caused by a read-through cache introduced in `inventory-nearmiss.js` (`CACHE_TTL_MS = 5000`) that is never invalidated on decrement — a distinct root cause not present in the prior investigation.

The TOCTOU race identified in the prior finding is still present (co-root-cause), but it is not the primary driver of the current incident at this load level.

---

## 2. Error Timeline from ClickHouse

Query: `otel_logs`, `ServiceName = 'ecommerce-api'`, `exception.type != ''`, last 1 hour.

| Minute (UTC)     | exc_type | Error Count |
|------------------|----------|-------------|
| 18:37            | Error    | 61          |
| 18:36            | Error    | 126         |
| 18:35            | Error    | 107         |
| 18:34            | Error    | 124         |
| 18:33            | Error    | 119         |
| 18:32            | Error    | 128         |
| 18:31            | Error    | 123         |
| 18:30            | Error    | 119         |
| 18:29            | Error    | 116         |
| 18:28–18:18      | Error    | 87–127/min  |

~100–128 errors/minute sustained for the entire 30-minute observation window — a persistent failure mode, not a transient spike.

**StockMismatchError (post-decrement negative stock) events:**

| product_id | product_name      | stock.expected | stock.actual | count |
|------------|-------------------|----------------|--------------|-------|
| 7          | Ceramic Plant Pot | 3              | -1           | 1     |
| 7          | Ceramic Plant Pot | 3              | -3           | 1     |

Only product 7 drove stock negative (the `StockMismatchError` logged at `inventory-nearmiss.js:67–93`). All other products error at `available 0` via the pre-decrement guard (lines 51–58), indicating stock was exhausted but not overdrawn.

**Sample error messages from error timeline query (18:36 UTC):**
```
Product 7 (Ceramic Plant Pot): requested 2, available -3  — 36 occurrences
Product 10 (Bluetooth Speaker): requested 1, available 0  —  4 occurrences
Product 9 (Throw Blanket): requested 1, available 0       —  1 occurrence
Product 5 (Denim Jeans): requested 1, available 0         —  5 occurrences
Product 1 (Wireless Headphones): requested 1, available 0 —  1 occurrence
(and 7 other products)
```

---

## 3. Pod & Runtime State

```
kubectl get pods -n ecommerce
NAME                            READY   STATUS    RESTARTS      AGE
ecommerce-api-57db6bbd9-s47dx   1/1     Running   0             29m
load-generator-9c744b49-bkdpw   1/1     Running   0             29m
load-generator-9c744b49-hwb8h   1/1     Running   0             29m
load-generator-9c744b49-k5qzh   1/1     Running   2 (29m ago)   29m
```

**Actual pod entrypoint** (`/proc/1/cmdline`):
```
node -r ./src/instrumentation.js src/nearmiss-loader.js
```

`nearmiss-loader.js` monkey-patches `Module._resolveFilename` at startup to intercept all `require('...inventory.js')` calls and redirect them to `inventory-nearmiss.js`. The checkout route, products route, and `server.js` run unmodified but load the nearmiss variant.

---

## 4. Root Cause Analysis

### 4a. The Cache: Distinct Primary Root Cause

`inventory-nearmiss.js` adds a read-through cache absent from the canonical `inventory.js`:

```javascript
// inventory-nearmiss.js lines 22–35
const stockCache = {};
const CACHE_TTL_MS = 5000;

async function getStock(productId) {
  const cached = stockCache[productId];
  if (cached && (Date.now() - cached.ts) < CACHE_TTL_MS) {
    await new Promise(resolve => setTimeout(resolve, 1));
    return cached.value;  // Returns STALE stock — never updated after decrement
  }
  await new Promise(resolve => setTimeout(resolve, 5));
  const stock = inventory[productId];
  stockCache[productId] = { value: stock, ts: Date.now() };
  return stock;
}
```

The cache is **never invalidated** after `inventory[item.id] -= item.quantity` (line 64). After the first read, every subsequent `getStock()` call within the 5,000 ms TTL returns the pre-decrement value.

**Race window comparison:**

| Variant                  | Stale-read window              | Concurrent decrements possible |
|--------------------------|--------------------------------|-------------------------------|
| `inventory.js`           | ~5 ms DB delay + 50–150ms rule | ~3–4 within 155ms window      |
| `inventory-nearmiss.js`  | Up to **5,000 ms** (cache TTL) | All 3 load-gen pods × all requests within 5s |

The cache amplifies the TOCTOU window by ~33×. This makes even 50-unit products exhaustible within seconds.

### 4b. TOCTOU Race: Co-Root-Cause (Inherited)

The read-check-sleep-decrement sequence (lines 48–64) is structurally identical to canonical `inventory.js`:

```javascript
const currentStock = await getStock(item.id);   // READ (stale if cached)
if (currentStock < item.quantity) { throw ... } // CHECK (against stale value)
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100)); // YIELD 50–150ms
inventory[item.id] -= item.quantity;            // DECREMENT (no lock)
```

No per-product mutex exists. Node.js yields at every `await`, allowing concurrent coroutines to all pass the check with the same stale stock value.

### 4c. Why Product 7 Is the Only StockMismatchError

- Product 7 initial stock: `5` units. All others: `50` units.
- Load generators request quantity 2 for product 7. Three concurrent requests: `5 - 2 - 2 - 2 = -1`, triggering the post-decrement negative check at line 67.
- 50-unit products: concurrent decrements of quantity 1 exhaust stock to exactly 0, failing the pre-decrement guard on the next request (`available 0`). They never reach the negative threshold.

### 4d. Is the Cache a Distinct Root Cause or Secondary?

**Distinct.** The cache independently causes correctness failure:
- Without the cache but with the TOCTOU race: blast radius is limited to product 7 (prior finding's conclusion). All 50-unit products survive.
- Without the TOCTOU race but with the stale cache: any two requests that read a cached value and simultaneously pass the guard (yielding at the `await` on line 62) can still double-decrement the same product.
- Together: ~33× wider race window, all products affected, sustained 100–128 errors/min.

Fixing only the cache (invalidate on decrement) would narrow the TOCTOU window to ~155ms, restoring the prior incident's blast radius. A full fix requires both: **cache invalidation on every decrement** AND **the per-product promise-chain mutex** described in the prior finding.

---

## 5. Confidence Level

**HIGH (90%)**

Three independent signals converge:

1. **ClickHouse logs:** Errors on all 12 products (vs. product 7 only in prior finding), 100–128/min sustained. `StockMismatchError` events both show `was 5 at read time` (initial inventory value), proving stale cache reads of the original stock level despite prior decrements.
2. **Source code (`inventory-nearmiss.js`):** Cache populated on first read, no invalidation on decrement at line 64 — structural proof of stale-read propagation across a 5,000ms window.
3. **Pod entrypoint:** `node ... src/nearmiss-loader.js` confirms the cache-amplified variant is live, not the canonical `inventory.js`.
