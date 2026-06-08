# Fix Proposal: ecommerce-api | StockMismatchError (e2836e74)
**Date:** 2026-06-04
**File:** `otel-demo/ecommerce/backend/src/services/inventory.js`

---

## Root Cause (Summary)

`reserveInventory()` has a TOCTOU race: it reads stock, waits 50–150 ms, then decrements — with no locking. Multiple concurrent coroutines all read `stock = 5`, pass the check, then all decrement, driving stock negative.

---

## Fix: Per-product async mutex

Add a minimal promise-chain mutex keyed by `product_id`. No new dependencies required.

### Change 1 — Add mutex infrastructure (after line 19)

```js
// Per-product mutex: maps productId -> Promise (the tail of the lock chain)
const locks = {};

function acquireLock(productId) {
  let release;
  const prev = locks[productId] || Promise.resolve();
  locks[productId] = prev.then(() => new Promise(resolve => { release = resolve; }));
  return prev.then(() => release);
}
```

### Change 2 — Wrap the read-check-decrement block (lines 38–85) inside the lock

Replace the existing per-item block:

```js
// BEFORE (no locking — races here)
const currentStock = await getStock(item.id);
...
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));
inventory[item.id] -= item.quantity;
const newStock = inventory[item.id];
```

With:

```js
// AFTER — lock per product for the duration of read-check-decrement
const release = await acquireLock(item.id);
try {
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
  const newStock = inventory[item.id];

  if (newStock < 0) {
    // ... existing StockMismatchError block unchanged ...
  }

  // ... existing INFO log + reserved.push unchanged ...
} finally {
  release();
}
```

---

## Why this fix is minimal and correct

| Property | Detail |
|----------|--------|
| **Atomicity** | Only one coroutine holds the lock for a given `productId` at a time; `getStock` → check → decrement is now a critical section |
| **Scope** | Lock is per-product, so products 1–6 and 8–12 are unaffected and can still process concurrently |
| **No new deps** | Uses native Promise chaining; no npm package needed |
| **No refactor** | All existing span attributes, logger calls, and error shapes are preserved exactly |
| **Correctness** | `finally { release() }` ensures the lock is always released even if the block throws |

---

## Full patched `reserveInventory` section (diff style)

```diff
+// Per-product mutex: maps productId -> Promise (tail of the lock chain)
+const locks = {};
+function acquireLock(productId) {
+  let release;
+  const prev = locks[productId] || Promise.resolve();
+  locks[productId] = prev.then(() => new Promise(resolve => { release = resolve; }));
+  return prev.then(() => release);
+}
+
 async function reserveInventory(items) {
   return tracer.startActiveSpan('reserveInventory', async (span) => {
     const reserved = [];
     try {
       for (const item of items) {
         const productName = PRODUCT_NAMES[item.id] || `Product ${item.id}`;
         span.setAttribute(`product.${item.id}.name`, productName);
         span.setAttribute(`product.${item.id}.requested`, item.quantity);

-        // ---- read current stock ----
-        const currentStock = await getStock(item.id);
-        span.setAttribute(`product.${item.id}.stock_before`, currentStock);
-
-        if (currentStock < item.quantity) {
-          ...
-        }
-
-        await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));
-
-        inventory[item.id] -= item.quantity;
-        const newStock = inventory[item.id];
-
-        if (newStock < 0) {
-          ...
-        }
+        const release = await acquireLock(item.id);
+        try {
+          // ---- read current stock (now inside lock) ----
+          const currentStock = await getStock(item.id);
+          span.setAttribute(`product.${item.id}.stock_before`, currentStock);
+
+          if (currentStock < item.quantity) {
+            ...
+          }
+
+          await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));
+
+          inventory[item.id] -= item.quantity;
+          const newStock = inventory[item.id];
+
+          if (newStock < 0) {
+            ...
+          }
+        } finally {
+          release();
+        }
       }
       ...
```

---

*Fix is read-only proposal. No cluster changes made. No files modified.*
