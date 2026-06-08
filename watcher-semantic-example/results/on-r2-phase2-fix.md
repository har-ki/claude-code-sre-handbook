# Phase 2 Fix Proposal — Incident e2836e74
**Service:** ecommerce-api
**Date:** 2026-06-05
**File:** `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js`

---

## Root Cause (summary)

TOCTOU race in `reserveInventory()`: concurrent coroutines all read the same `currentStock` value, pass the pre-decrement guard, then sleep 50–150 ms (yielding to the event loop), and all decrement — driving stock sub-zero. A 5-second read-through cache amplifies the race window and makes the resulting error flood permanent until process restart.

---

## Minimal Fix

Add a per-product promise-chain mutex that serializes the entire read-check-sleep-decrement sequence. Invalidate the cache entry inside the locked section so the next holder reads fresh state.

### Diff (to apply at `inventory-nearmiss.js`)

```diff
--- a/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js
+++ b/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js
@@ -20,6 +20,21 @@ const inventory = {
 // Read-through cache for stock lookups — reduces load on the backing store
 const stockCache = {};
 const CACHE_TTL_MS = 5000;
+
+// Per-product mutex: maps productId → Promise tail.
+// Each caller chains onto the tail; the critical section runs after all
+// prior holders have resolved, serializing read-check-decrement per product.
+const productLocks = {};
+
+function acquireLock(productId) {
+  const prev = productLocks[productId] || Promise.resolve();
+  let releaseLock;
+  productLocks[productId] = prev.then(
+    () => new Promise(resolve => { releaseLock = resolve; })
+  );
+  return prev.then(() => releaseLock);
+}

 async function getStock(productId) {
   const cached = stockCache[productId];
@@ -43,8 +58,15 @@ async function reserveInventory(items) {
         span.setAttribute(`product.${item.id}.requested`, item.quantity);

-        const currentStock = await getStock(item.id);
+        // Acquire per-product lock before reading stock.
+        // All concurrent callers for the same product queue here.
+        const release = await acquireLock(item.id);
+        // Bypass potentially stale cache: invalidate so getStock re-reads
+        delete stockCache[item.id];
+        const currentStock = await getStock(item.id);
         span.setAttribute(`product.${item.id}.stock_before`, currentStock);

         if (currentStock < item.quantity) {
           const err = new Error(
              `Insufficient stock for product ${item.id} (${productName}): ` +
               `requested ${item.quantity}, available ${currentStock}`
           );
           span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
           span.recordException(err);
+          release();
           throw err;
         }

         // Validate inventory policies and apply business rules
         await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

         inventory[item.id] -= item.quantity;
+        // Invalidate cache so next holder reads the decremented value
+        delete stockCache[item.id];
+        release();
         const newStock = inventory[item.id];
```

### Full patched critical section (lines 43–65 after fix)

```javascript
const release = await acquireLock(item.id);
delete stockCache[item.id];                          // force fresh read inside lock
const currentStock = await getStock(item.id);
span.setAttribute(`product.${item.id}.stock_before`, currentStock);

if (currentStock < item.quantity) {
  const err = new Error(
    `Insufficient stock for product ${item.id} (${productName}): ` +
    `requested ${item.quantity}, available ${currentStock}`
  );
  span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
  span.recordException(err);
  release();
  throw err;
}

// Validate inventory policies and apply business rules
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

inventory[item.id] -= item.quantity;
delete stockCache[item.id];                          // invalidate after write
release();
const newStock = inventory[item.id];
```

---

## Why this is minimal

| Change | Lines | Purpose |
|---|---|---|
| `productLocks` map + `acquireLock()` | +14 | Serializes per-product critical section |
| `delete stockCache[item.id]` (×2) | +2 | Prevents stale cache reads inside/after lock |
| `release()` calls (×2) | +2 | Unlock on both success and error paths |

No schema changes, no new dependencies, no API changes. The cache still works for read-only stock queries outside the reservation path.

---

## Verification

After applying, restart the pod and re-run the load generator. Expected outcomes:
- `StockMismatchError` count drops to 0
- Product 7 stock depletes to 0 (not sub-zero) then returns clean "Insufficient stock" errors
- No `available -3` messages in logs
