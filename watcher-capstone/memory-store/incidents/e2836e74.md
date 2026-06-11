# Prior Finding: e2836e74

## Root Cause
`reserveInventory()` in `otel-demo/ecommerce/backend/src/services/inventory.js` has a TOCTOU race condition across lines 39–55. The function reads stock via `await getStock(item.id)` (5 ms simulated DB delay), validates `currentStock >= item.quantity`, then sleeps 50–150 ms for "business rule validation," and only then decrements `inventory[item.id]`. Because Node.js yields control at every `await`, multiple concurrent coroutines can all read `currentStock = 5`, all pass the pre-decrement check, and all proceed to decrement — driving stock negative. Product 7 (Ceramic Plant Pot) is uniquely affected because it is initialized with only 5 units while all other products have 50; under load from 3 concurrent load-generator pods requesting quantity 2, the race window (55–155 ms) is wide enough to exhaust product 7's stock within seconds of startup.

## Fix Pattern
Introduce a per-product promise-chain mutex (`acquireLock(productId)`) using no external dependencies. Add a module-scoped `locks` object and a 6-line `acquireLock` helper immediately after the `inventory` declaration. Before the `getStock` call for each item, acquire the lock; release it in a `finally` block after the decrement. This makes the read-check-decrement sequence atomic per product, eliminating the TOCTOU window.

## Resolved
2026-06-04 via canonical capture
