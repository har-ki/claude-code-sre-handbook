# Fix Proposal: e2836e74 — Inventory TOCTOU Race Condition

## Root Cause

`reserveInventory` in `services/inventory.js` reads stock via `getStock()` (5 ms async delay), then waits 50–150 ms for "business rule validation", then unconditionally decrements `inventory[item.id]`. Concurrent checkout requests both read the same stock value, both pass the pre-check, then both decrement — driving stock below zero. The post-decrement guard logs an error but the damage is already done (inventory is now negative in memory).

## Affected File

`otel-demo/ecommerce/backend/src/services/inventory.js`, lines 39–85

## Minimal Fix

Add a second stock check immediately before the decrement (after the async delay), using the live in-memory value rather than the stale `currentStock` snapshot:

```diff
-        inventory[item.id] -= item.quantity;
-        const newStock = inventory[item.id];
-
-        if (newStock < 0) {
+        // Re-check with current value to close TOCTOU window
+        if (inventory[item.id] < item.quantity) {
+          const err = new Error(
+            `Insufficient stock for product ${item.id} (${productName}): ` +
+            `requested ${item.quantity}, available ${inventory[item.id]} (updated after delay)`
+          );
+          span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
+          span.recordException(err);
+          throw err;
+        }
+        inventory[item.id] -= item.quantity;
+        const newStock = inventory[item.id];
+
+        if (newStock < 0) {   // defensive: should now be unreachable
```

The early `currentStock < item.quantity` check on line 42 can remain for fast-fail UX; the new check right before the write closes the race window.

## Why This Is Minimal

- No new dependencies, no locking library needed.
- One extra in-memory read (< 1 µs) before the decrement.
- Preserves all existing OTel span attributes and log shapes.
- The post-decrement negative guard becomes a defensive dead-code path, safe to leave in place.
