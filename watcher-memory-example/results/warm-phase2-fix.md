# Fix Proposal: ecommerce-api | StockMismatchError (e2836e74)
**Date:** 2026-06-04
**File:** `otel-demo/ecommerce/backend/src/services/inventory.js`

---

## Root Cause (confirmed)

`reserveInventory()` has a TOCTOU race condition across lines 39–55. Three concurrent load-generator
pods all `await getStock(item.id)` (line 39, 5 ms yield), each read `currentStock = 5`, each pass
the `>= 2` check, then all sleep 50–150 ms (line 53, another yield), and finally all decrement
`inventory[7]` — producing `5 - 2 - 2 - 2 = -1` (or `-3` if a fourth overlapping request sneaks in).

---

## Proposed Fix — Per-Product Promise-Chain Mutex

Add a `locks` map and an `acquireLock` helper immediately after the `inventory` declaration
(after line 19), then wrap the per-item read-check-decrement block (lines 39–85) with
acquire/release calls.

### 1. Add the mutex helper (insert after line 19)

```js
// Per-product mutex — promise-chain lock, no external deps
const locks = {};
function acquireLock(productId) {
  const prev = locks[productId] || Promise.resolve();
  let release;
  locks[productId] = prev.then(() => new Promise(res => { release = res; }));
  return prev.then(() => release);
}
```

### 2. Wrap the per-item block inside the `for` loop

Replace the existing for-loop body (lines 33–100 inside the loop) with:

```js
for (const item of items) {
  const productName = PRODUCT_NAMES[item.id] || `Product ${item.id}`;
  span.setAttribute(`product.${item.id}.name`, productName);
  span.setAttribute(`product.${item.id}.requested`, item.quantity);

  const release = await acquireLock(item.id);   // <-- ADDED
  try {
    // ---- read current stock ----
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
      const err = new Error(
         `Inventory inconsistency: stock for product ${item.id} ` +
          `(${productName}) is ${newStock} after decrement ` +
          `(was ${currentStock} at read time)`
      );
      err.productId = item.id;
      err.finalStock = newStock;

      logger.emit({
        severityNumber: SeverityNumber.ERROR,
        severityText: 'ERROR',
        body: err.message,
        attributes: {
            'exception.type': 'StockMismatchError',
            'exception.message': err.message,
            'exception.stacktrace': err.stack,
            'product.id': String(item.id),
            'product.name': productName,
            'stock.expected': String(currentStock - item.quantity),
            'stock.actual': String(newStock),
          },
      });

      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      throw err;
    }

    logger.emit({
      severityNumber: SeverityNumber.INFO,
      severityText: 'INFO',
      body: `Reserved ${item.quantity} unit(s) of ${productName} — stock: ${currentStock} -> ${newStock}`,
      attributes: {
          'product.id': String(item.id),
          'product.name': productName,
          'stock.before': String(currentStock),
          'stock.after': String(newStock),
        },
    });

    reserved.push({ id: item.id, name: productName, reserved: item.quantity, remaining: newStock });
  } finally {
    release();                                    // <-- ADDED
  }
}
```

---

## Why This Works

The promise-chain mutex serializes all coroutines that attempt to reserve the **same** product.
When coroutine A holds the lock, coroutines B and C queue behind the chained promise. By the time
B acquires the lock, `inventory[7]` already reflects A's decrement — so B correctly reads the
updated value and throws `Insufficient stock` instead of over-decrementing.

Products 1–6 and 8–12 each have their own independent lock key, so they continue processing
concurrently with no throughput impact.

---

## Scope of Change

- **Added:** 6-line `acquireLock` helper + `locks` object (after line 19)
- **Added:** `const release = await acquireLock(item.id);` before the stock read
- **Added:** `try { ... } finally { release(); }` wrapping lines 39–99
- **Unchanged:** All span attributes, logger calls, error shapes, exports, and OTel instrumentation

---

## Risk Assessment

- **Low risk** — pure in-process serialization, no external dependencies, no schema changes
- The lock object (`locks`) is module-scoped and lives for the process lifetime; memory cost is
  O(distinct product IDs) ≈ 12 entries
- If the process restarts, `inventory` resets to initial values (same as today) — no regression
