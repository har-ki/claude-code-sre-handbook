# Fix Proposal: ecommerce-api | StockMismatchError
**Fingerprint:** `e2836e74` | **Date:** 2026-06-04 | **Phase:** 2

---

## Root Cause (Summary)

`reserveInventory()` in `inventory-nearmiss.js` has a TOCTOU race condition.
The read-validate-sleep-decrement sequence spans 51–165 ms with no mutual
exclusion. Multiple concurrent coroutines all read the same cached stock value,
all pass the guard check, all sleep, and all decrement — driving stock negative.
The 5-second `stockCache` TTL worsens the race by serving stale pre-decrement
values to coroutines that enter after a decrement already occurred.

---

## Minimal Fix

Add a **per-product promise-chain mutex** immediately after the `inventory`
declaration. No external dependencies required.

### Diff: `inventory-nearmiss.js`

```diff
 // In-memory inventory store — simulates a database table
 const inventory = {
    1: 50, 2: 50, 3: 50, 4: 50, 5: 50, 6: 50,
    7: 5,      // Ceramic Plant Pot — limited stock
    8: 50, 9: 50, 10: 50, 11: 50, 12: 50,
 };

+// Per-product mutex: chains Promises so only one coroutine holds the lock
+// for a given productId at a time.
+const locks = {};
+function acquireLock(productId) {
+  const prev = locks[productId] || Promise.resolve();
+  let release;
+  locks[productId] = new Promise(resolve => { release = resolve; });
+  return prev.then(() => release);
+}

 // Read-through cache for stock lookups — reduces load on the backing store
 const stockCache = {};
 const CACHE_TTL_MS = 5000;
```

```diff
       for (const item of items) {
         const productName = PRODUCT_NAMES[item.id] || `Product ${item.id}`;
         span.setAttribute(`product.${item.id}.name`, productName);
         span.setAttribute(`product.${item.id}.requested`, item.quantity);

+        const release = await acquireLock(item.id);
+        // Invalidate cache so we read committed stock, not a stale snapshot.
+        delete stockCache[item.id];
+        try {
         const currentStock = await getStock(item.id);
         span.setAttribute(`product.${item.id}.stock_before`, currentStock);

         if (currentStock < item.quantity) {
           const err = new Error(
              `Insufficient stock for product ${item.id} (${productName}): ` +
               `requested ${item.quantity}, available ${currentStock}`
           );
           span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
           span.recordException(err);
           throw err;
         }

         // Validate inventory policies and apply business rules
         await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

         inventory[item.id] -= item.quantity;
+        } finally {
+          release();
+        }
         const newStock = inventory[item.id];
```

---

## Why this works

`acquireLock(productId)` creates a per-product promise chain:
- Each caller receives a promise that resolves only after the previous caller's
  `release()` fires.
- The entire **read → guard → sleep → decrement** block executes as a single
  atomic critical section per product.
- Even with 3 concurrent load-generator pods, only one coroutine per product
  proceeds through the race window at a time.
- Cache invalidation at lock acquisition ensures the first `getStock()` inside
  the lock sees the committed post-decrement value, not a 5-second-old snapshot.

---

## Scope

- **File:** `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js`
- **Lines changed:** +10 lines (mutex helper + lock/release wrappers)
- **No new dependencies.**
- `nearmiss-loader.js` is unchanged — it is a module-redirect shim only.
- `inventory.js` (canonical) is unchanged — fix targets only the nearmiss variant.

---

## Expected outcome

- `StockMismatchError` rate drops to 0% once the fix is deployed and the pod
  restarts (inventory resets to initial values on restart).
- Stock will never go negative because only one coroutine per product can
  proceed past the guard at a time.
- Legitimate `InsufficientStock` errors (requested > actual stock) are preserved
  — the guard check remains in place.
