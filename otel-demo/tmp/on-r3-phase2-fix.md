# Phase 2 Fix — on-r3 — ecommerce-api | StockMismatchError

**Fingerprint:** `ecommerce-api|StockMismatchError`
**Hash:** `e2836e74`
**Date:** 2026-06-05
**File:** `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js`

---

## Root Cause (Summary)

Two co-root-causes:

1. **Stale cache (primary):** `getStock()` caches stock values for 5,000 ms but the cache entry is never invalidated after `inventory[item.id] -= item.quantity` (line 64). All concurrent coroutines within the TTL window read the pre-decrement stock level, pass the guard check, and all decrement — amplifying the TOCTOU window by ~33×.

2. **TOCTOU race (inherited):** No per-product mutex exists. Node.js yields at every `await`, allowing multiple coroutines to pass the guard simultaneously with the same (stale) stock value.

---

## Minimal Fix

Two targeted changes to `inventory-nearmiss.js`:

### Fix 1 — Invalidate cache on every decrement (lines 64–65)

```diff
-       inventory[item.id] -= item.quantity;
-       const newStock = inventory[item.id];
+       inventory[item.id] -= item.quantity;
+       delete stockCache[item.id];          // Invalidate stale cache entry
+       const newStock = inventory[item.id];
```

**Why:** Ensures the next `getStock()` call for this product performs a fresh read from `inventory[]` rather than returning the pre-decrement cached value. Eliminates the 5,000 ms stale-read window.

### Fix 2 — Per-product promise-chain mutex (module level + reserveInventory)

Add a per-product lock map at the top of the file:

```javascript
// Per-product serialization lock — prevents concurrent decrement races
const productLocks = {};

async function withProductLock(productId, fn) {
  const prev = productLocks[productId] || Promise.resolve();
  let release;
  productLocks[productId] = new Promise(resolve => { release = resolve; });
  productLocks[productId] = prev.then(async () => {
    try { return await fn(); }
    finally { release(); }
  });
  return productLocks[productId];
}
```

Wrap the per-item block inside `reserveInventory` with the lock:

```diff
     for (const item of items) {
-      const productName = PRODUCT_NAMES[item.id] || `Product ${item.id}`;
-      // ... existing read-check-sleep-decrement logic ...
+      await withProductLock(item.id, async () => {
+        const productName = PRODUCT_NAMES[item.id] || `Product ${item.id}`;
+        // ... existing read-check-sleep-decrement logic unchanged ...
+      });
     }
```

**Why:** Serializes all `reserveInventory` calls for the same `productId`. Only one coroutine at a time can hold the lock, so the read-check-decrement sequence is atomic per product. Eliminates the 50–150 ms TOCTOU window entirely.

---

## Impact Assessment

| Change | Fixes | Risk |
|--------|-------|------|
| `delete stockCache[item.id]` after decrement | Primary root cause (stale cache) | None — one-liner, no logic change |
| Per-product promise-chain mutex | TOCTOU race | Low — serializes per-product only, not global; no I/O added |

Fix 1 alone would reduce blast radius back to product 7 only (prior incident profile) but would not fully eliminate races at high load. Both fixes together fully resolve the incident.

---

## Lines to Change

- `inventory-nearmiss.js:64` — add `delete stockCache[item.id];` after the decrement
- `inventory-nearmiss.js:22` — add `productLocks` map and `withProductLock` helper
- `inventory-nearmiss.js:43` — wrap item loop body in `withProductLock(item.id, ...)`

Total: ~15 lines added, 0 lines removed from business logic.
