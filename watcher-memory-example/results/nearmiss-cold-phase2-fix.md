# Phase 2 Fix Proposal — ecommerce-api StockMismatchError

**Fingerprint:** `ecommerce-api|StockMismatchError` (`e2836e74`)
**Date:** 2026-06-04

---

## Root Cause (Summary)

`inventory-nearmiss.js` has a **read-check-delay-write** race condition amplified by a 5-second read-through cache:

1. `getStock()` returns a cached (stale) value for up to 5 seconds
2. Multiple concurrent requests all pass the `currentStock >= quantity` check using the same stale value
3. A 50–150ms artificial `await` between the check and the decrement widens the race window
4. All concurrent requests then decrement `inventory[item.id]` unconditionally, driving stock negative

JavaScript is single-threaded, but `await` yields the event loop — any `await` between the check and the write is an opening for other coroutines to interleave.

---

## Minimal Fix

Move the decrement **synchronously** immediately after the stock check, before any `await`. Since Node.js is single-threaded, the check + decrement will execute atomically (no other coroutine can run between two synchronous statements). Also invalidate the cache on every write so subsequent reads see the updated value.

### Diff — `inventory-nearmiss.js`

```diff
-       const currentStock = await getStock(item.id);
-       span.setAttribute(`product.${item.id}.stock_before`, currentStock);
-
-       if (currentStock < item.quantity) {
-         const err = new Error(
-            `Insufficient stock for product ${item.id} (${productName}): ` +
-             `requested ${item.quantity}, available ${currentStock}`
-         );
-         span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
-         span.recordException(err);
-         throw err;
-       }
-
-       // Validate inventory policies and apply business rules
-       await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));
-
-       inventory[item.id] -= item.quantity;
-       const newStock = inventory[item.id];
+       // Read live stock (bypass cache for reservation — stale reads cause oversell)
+       const currentStock = inventory[item.id];
+       span.setAttribute(`product.${item.id}.stock_before`, currentStock);
+
+       if (currentStock < item.quantity) {
+         const err = new Error(
+            `Insufficient stock for product ${item.id} (${productName}): ` +
+             `requested ${item.quantity}, available ${currentStock}`
+         );
+         span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
+         span.recordException(err);
+         throw err;
+       }
+
+       // Decrement SYNCHRONOUSLY before any await — JS single-thread guarantees
+       // no other coroutine runs between here and the next await.
+       inventory[item.id] -= item.quantity;
+       const newStock = inventory[item.id];
+       // Invalidate cache so subsequent reads reflect the new value
+       delete stockCache[item.id];
+
+       // Validate inventory policies and apply business rules (async OK now — stock already committed)
+       await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));
```

### Full replacement for `reserveInventory` inner loop (lines 43–108)

```js
for (const item of items) {
  const productName = PRODUCT_NAMES[item.id] || `Product ${item.id}`;
  span.setAttribute(`product.${item.id}.name`, productName);
  span.setAttribute(`product.${item.id}.requested`, item.quantity);

  // Read live stock synchronously — no cache, no await before the check+decrement
  const currentStock = inventory[item.id];
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

  // Atomic check-and-decrement: synchronous, no await between check and write
  inventory[item.id] -= item.quantity;
  const newStock = inventory[item.id];
  delete stockCache[item.id]; // invalidate cache

  // Async work happens AFTER stock is committed — race window is closed
  await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

  // newStock < 0 is now impossible — guard retained for defence-in-depth only
  if (newStock < 0) {
    // ... existing StockMismatchError path unchanged ...
  }

  // ... existing INFO log + reserved.push unchanged ...
}
```

---

## Why This Fix Is Sufficient

| Problem | Fix |
|---|---|
| Stale cache causes multiple requests to pass stock check on same value | Read `inventory[item.id]` directly — always live |
| `await` between check and decrement lets other coroutines interleave | Decrement moved before any `await` — JS event loop guarantees atomicity |
| Cache not updated after write | `delete stockCache[item.id]` ensures next reader re-populates from live value |

No mutex, no lock file, no external coordination needed — Node.js's own event-loop guarantee is sufficient here.

---

## What Is NOT Changed

- OTel spans and log emission — no changes to observability
- The `getStock()` function — left intact (used by other callers or future reads; cache is fine for non-reservation reads)
- The `nearmiss-loader.js` module swap — a separate deployment concern; this fix corrects `inventory-nearmiss.js` itself
- Business logic delay (50–150ms) — retained, now safe because it runs after the decrement

---

## Deployment Note

The near-term correct fix is also to remove `nearmiss-loader.js` from the pod startup command and run `node -r ./src/instrumentation.js src/server.js` instead. That returns to the canonical `inventory.js` which has no cache at all. The code fix above addresses the module that is currently running in production.
