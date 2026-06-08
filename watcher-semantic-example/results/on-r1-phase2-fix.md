# Phase 2 Fix Proposal: ecommerce-api | StockMismatchError
**Fingerprint:** `e2836e74`
**Date:** 2026-06-05
**File:** `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js`

---

## Root Cause (Summary)

TOCTOU race in `reserveInventory()`: multiple concurrent coroutines all read `currentStock`, all pass the pre-decrement guard, then all sleep 50–150 ms (yielding to each other), then all decrement — driving stock sub-zero. The 5-second read-through cache amplifies the damage by serving the stale `-3` value for up to 5 seconds after each race event, converting two race events into a sustained error storm.

---

## Minimal Fix

Introduce a per-product promise-chain mutex that serialises the entire **read → check → sleep → decrement** sequence for each `productId`. The mutex must wrap lines 48–64 (the full critical section). The cache must be bypassed or invalidated inside the locked section so the post-lock read always reflects committed state.

### Patch (inventory-nearmiss.js)

```diff
--- a/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js
+++ b/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js
@@ -21,6 +21,16 @@ const inventory = {
 // Read-through cache for stock lookups — reduces load on the backing store
 const stockCache = {};
 const CACHE_TTL_MS = 5000;
+
+// Per-product mutex: maps productId -> Promise (tail of the lock chain)
+const lockChain = {};
+
+function acquireLock(productId) {
+  const prev = lockChain[productId] || Promise.resolve();
+  let release;
+  lockChain[productId] = new Promise(resolve => { release = resolve; });
+  return prev.then(() => release);
+}

 async function getStock(productId) {
   const cached = stockCache[productId];
@@ -43,8 +53,11 @@ async function reserveInventory(items) {
         span.setAttribute(`product.${item.id}.name`, productName);
         span.setAttribute(`product.${item.id}.requested`, item.quantity);

-        const currentStock = await getStock(item.id);
+        // Acquire per-product lock before reading to close the TOCTOU window
+        const release = await acquireLock(item.id);
+        // Bypass cache inside lock: read committed value from inventory store
+        const currentStock = inventory[item.id];
         span.setAttribute(`product.${item.id}.stock_before`, currentStock);

         if (currentStock < item.quantity) {
@@ -61,7 +74,10 @@ async function reserveInventory(items) {
         // Validate inventory policies and apply business rules
         await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

-        inventory[item.id] -= item.quantity;
+        inventory[item.id] -= item.quantity;
+        // Invalidate cache so the next getStock() outside the lock reflects new value
+        delete stockCache[item.id];
+        release();
         const newStock = inventory[item.id];
```

---

## Why This Works

| Before | After |
|--------|-------|
| All concurrent coroutines read `currentStock = 5`, pass the guard, sleep, then decrement concurrently | Each coroutine acquires the lock before reading; subsequent coroutines queue behind the chain |
| Race window: 50–150 ms sleep with no synchronisation | Race window: eliminated — only one coroutine holds the lock at a time per product |
| Cache serves stale `-3` for 5 s after race | Cache invalidated on every successful decrement; next read reflects committed value |

---

## What Is NOT Changed

- No changes to `nearmiss-loader.js`, `inventory.js`, or any other file.
- OTel instrumentation is preserved.
- The sleep (business-rule simulation) is preserved — the lock wraps it, not removes it.
- The post-decrement `newStock < 0` guard is preserved as a safety net.

---

## Deployment Note

The fix must be applied to `inventory-nearmiss.js` (the active module). `inventory.js` is shadowed by `nearmiss-loader.js` and is not executed. To remove the nearmiss scenario entirely, revert the pod command from `src/nearmiss-loader.js` to `src/server.js`.
