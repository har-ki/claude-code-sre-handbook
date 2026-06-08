# Fix Proposal — Incident e2836e74 (2026-06-05)

## Root Cause

`reserveInventory` in `services/inventory.js` has a TOCTOU (Time-of-Check / Time-of-Use) race condition. The function reads `currentStock` (line 39), then awaits a 50–150 ms simulated delay (line 53), then blindly decrements `inventory[item.id]` (line 55). Because Node.js yields at every `await`, two concurrent checkout requests for the same product can both pass the `currentStock < item.quantity` guard with the same pre-decrement stock value, then both decrement — driving the counter negative and triggering the `StockMismatchError` on line 58–85.

## Minimal Fix

Re-validate stock at decrement time (after the delay), inside the same synchronous step — no second async call needed since `inventory` is an in-memory object and JS is single-threaded between awaits.

**File:** `otel-demo/ecommerce/backend/src/services/inventory.js`

Replace lines 52–55:

```js
// BEFORE
// Validate inventory policies and apply business rules
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

inventory[item.id] -= item.quantity;
```

```js
// AFTER
// Validate inventory policies and apply business rules
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

// Re-check synchronously before decrement to close the TOCTOU window
const stockAtDecrement = inventory[item.id];
if (stockAtDecrement < item.quantity) {
  throw new Error(
    `Insufficient stock for product ${item.id} (${productName}): ` +
    `requested ${item.quantity}, available ${stockAtDecrement} (concurrent reservation)`
  );
}
inventory[item.id] -= item.quantity;
```

This closes the race: by the time the `await` resolves, `inventory[item.id]` reflects any concurrent decrements that completed during the delay. The synchronous re-check and decrement are never interrupted by another request.

## Impact

- Eliminates `StockMismatchError` / `Inventory inconsistency` 500 errors under concurrent load.
- Returns a proper 409 to the losing concurrent request (the `err.message.includes('Insufficient stock')` branch in `checkout.js:87` already handles this).
- No schema changes, no new dependencies, no data-layer changes required.
