# Incident Findings: ecommerce-api | StockMismatchError
**Fingerprint:** `ecommerce-api|StockMismatchError` (hash `e2836e74`)
**Investigation date:** 2026-06-05
**Investigator:** SRE Agent (off-r1-phase1)

---

## 1. Memory Status and Validation

**Prior finding loaded:** hash `e2836e74`, similarity score 0.80.

**Classification: PARTIALLY CONFIRMED — NEW VARIANT**

The prior finding accurately described the TOCTOU race condition in `reserveInventory()`. However, the pod is **not** running the canonical `inventory.js` — it is running `inventory-nearmiss.js` via `nearmiss-loader.js`. This near-miss variant introduces a **read-through cache** not present in the prior finding, which acts as a secondary amplifier of the race condition.

Memory status: root cause class matches; specific code path and cache amplification are **new and distinct**.

---

## 2. Pod State

```
NAME                            READY   STATUS    RESTARTS
ecommerce-api-57db6bbd9-s47dx   1/1     Running   0
load-generator-9c744b49-bkdpw   1/1     Running   0
load-generator-9c744b49-hwb8h   1/1     Running   0
load-generator-9c744b49-k5qzh   1/1     Running   2 (10m ago)
```

The API pod is healthy (no restarts). Three load-generator pods are active (one has 2 restarts).

**Actual entrypoint** (from `/proc/1/cmdline`):
```
node -r ./src/instrumentation.js src/nearmiss-loader.js
```

**Environment variable:** `INVENTORY_VARIANT=nearmiss`

The pod is running `nearmiss-loader.js`, which monkey-patches Node's `require()` to redirect all imports of `services/inventory.js` → `services/inventory-nearmiss.js`. The rest of the app (checkout, products, server) runs unmodified but consumes the nearmiss variant transparently.

---

## 3. Error Timeline (from ClickHouse `otel_logs`)

Query window: `now() - INTERVAL 2 HOUR`, service `ecommerce-api`.

| Minute (UTC-7) | Error Count | Exception Type |
|---|---|---|
| 18:06 | 2 | `StockMismatchError` |
| 18:06 | 2 | `Error` |
| 18:07 | 52 | `Error` |
| 18:08 | 64 | `Error` |
| 18:09 | 68 | `Error` |
| 18:10 | 64 | `Error` |
| 18:11 | 60 | `Error` |
| 18:12 | 72 | `Error` |
| 18:13 | 56 | `Error` |
| 18:14 | 60 | `Error` |
| 18:15 | 69 | `Error` |
| 18:16 | 73 | `Error` |
| 18:17 | 19 | `Error` (partial minute) |

**Phase 1 (18:06):** 2 `StockMismatchError` events — the TOCTOU race fires, driving `inventory[7]` to **-3** (product 7, Ceramic Plant Pot, initialized at 5 units with 3 concurrent coroutines each requesting qty 2).

**Phase 2 (18:07–18:17):** ~60–73 generic `Error` events per minute. Representative message:
```
Checkout failed: order=ORD-95C90E64 — Insufficient stock for product 7
(Ceramic Plant Pot): requested 2, available -3
```
Every checkout touching product 7 now fails the pre-decrement guard (`currentStock < item.quantity` where `currentStock = -3`). Stock is permanently exhausted at -3.

One outlier at 18:07:
```
Checkout failed: order=ORD-9D331B06 — Insufficient stock for product 6
(Running Shoes): requested 1, available 0
```
Product 6 (Running Shoes) also depleted — consistent with 50 units × concurrent load across all products.

**Total errors in window:** ~792+ over 11 minutes; near-continuous after the initial race event.

---

## 4. Root Cause Analysis

### Primary Root Cause: TOCTOU Race in `reserveInventory()` — `inventory-nearmiss.js`

The near-miss variant at `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js` has the same TOCTOU race as the canonical file, with an added cache layer:

**Race window (lines 48–64):**
```javascript
// Line 48: read stock (yields event loop)
const currentStock = await getStock(item.id);   // 1–5 ms delay

// Line 51: pre-decrement guard
if (currentStock < item.quantity) { throw ... }

// Line 62: 50–150 ms artificial delay (YIELDS EVENT LOOP — race window)
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

// Line 64: decrement (no re-check)
inventory[item.id] -= item.quantity;
```

With 3 concurrent load-generator coroutines:
1. All three call `getStock(7)` and read `currentStock = 5`
2. All three pass the guard (`5 >= 2`)
3. All three sleep 50–150 ms in the race window (event loop yielded)
4. All three decrement: `5 - 2 - 2 - 2 = -1`... actually with 3 concurrent: `inventory[7]` = 5 - 2 - 2 - 2 = **-1** (or worse, -3 based on observed `available -3` values, implying more than 3 concurrent decrements)

The `StockMismatchError` is thrown at lines 67–93 when `newStock < 0` is detected post-decrement.

### Secondary Factor: Read-Through Cache Widens Race Window

**Cache code (lines 21–34, unique to nearmiss variant):**
```javascript
const stockCache = {};
const CACHE_TTL_MS = 5000;   // 5-second TTL

async function getStock(productId) {
  const cached = stockCache[productId];
  if (cached && (Date.now() - cached.ts) < CACHE_TTL_MS) {
    await new Promise(resolve => setTimeout(resolve, 1));  // 1 ms (cache hit)
    return cached.value;
  }
  await new Promise(resolve => setTimeout(resolve, 5));    // 5 ms (cache miss)
  const stock = inventory[productId];
  stockCache[productId] = { value: stock, ts: Date.now() };
  return stock;
}
```

The cache amplifies the race in two ways:

1. **Stale positive value served to all concurrent readers (within 5s TTL):** The first coroutine that populates the cache at `stock=5` causes all coroutines within the next 5 seconds to receive `5` from cache, even if concurrent decrements have already occurred. This is worse than the canonical version where each reader incurs its own 5 ms DB delay (small but sequential in some cases).

2. **Negative stock cached and served indefinitely:** After the race drives `inventory[7] = -3`, `getStock(7)` reads `-3` from `inventory` and caches it as `{ value: -3, ts: now }`. For the next 5 seconds, all requests get -3 from cache with only 1 ms delay; after TTL expires, `getStock` re-reads `inventory[7] = -3` and re-caches -3. This is a steady-state loop — the negative value is permanent and cached, making every checkout attempt for product 7 fail instantly.

### Is the Cache a Distinct Root Cause?

**No — the cache is a secondary amplifier, not the root cause.**

The TOCTOU race would fire in the canonical `inventory.js` without the cache. The cache:
- Widens the "all readers see stale stock" window from ~5 ms to up to 5000 ms, making the race more likely to fire even at moderate concurrency
- Propagates the negative stock value at higher throughput (1 ms cache hit vs. 5 ms DB read)
- Does NOT introduce a new failure mode; it accelerates and entrenches the existing one

The fix must address the TOCTOU race (acquire-per-product lock around the read-check-decrement sequence). Fixing only the cache (e.g., removing it or using write-invalidation) would not prevent the race.

---

## 5. Confidence Level

**High (0.92)**

Evidence:
- Pod entrypoint confirmed via `/proc/1/cmdline` — running `nearmiss-loader.js`, not `server.js`
- `inventory-nearmiss.js` source read and analyzed directly
- ClickHouse timeline shows exactly 2 `StockMismatchError` events (race fires once, product 7 → -3), then sustained "available -3" errors consistent with permanent stock exhaustion
- Error messages include literal `available -3`, matching the post-race state of `inventory[7]`
- Cache TTL 5000 ms confirmed in source; behavior consistent with observed error pattern

Minor uncertainty: cannot determine exact number of concurrent decrements that drove stock to exactly -3 without trace-level correlation; -3 from initial stock of 5 implies 4 concurrent qty-2 decrements (5 - 2×4 = -3), or a combination including product 6 reads in the same span.
