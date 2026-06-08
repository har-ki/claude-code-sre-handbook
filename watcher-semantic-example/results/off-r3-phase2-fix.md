# Phase 2 Fix — off-r3 — ecommerce-api | StockMismatchError

**Fingerprint:** `ecommerce-api|StockMismatchError`
**Hash:** `e2836e74`
**Date:** 2026-06-05

---

## Root Cause Summary

Two co-root-causes compound into catastrophic stock overdraft:

1. **Cache not invalidated on decrement** (`inventory-nearmiss.js`, line 64 area): `stockCache` is populated on first read but never updated after `inventory[item.id] -= item.quantity`. All concurrent requests within the 5-second TTL window read the original pre-decrement stock value, producing a ~33× wider TOCTOU window than the canonical `inventory.js`.

2. **TOCTOU race** (both variants): The pattern is read → `await sleep(50–150ms)` → decrement with no locking. Multiple concurrent coroutines pass the stock-sufficiency guard simultaneously, then all decrement, driving stock negative.

---

## Minimal Fix: `inventory-nearmiss.js`

### Change 1 — Invalidate cache after decrement (line ~64)

**Before:**
```javascript
inventory[item.id] -= item.quantity;
const newStock = inventory[item.id];
```

**After:**
```javascript
inventory[item.id] -= item.quantity;
const newStock = inventory[item.id];
// Invalidate cache so next read reflects the decrement
delete stockCache[item.id];
```

This eliminates stale-cache reads. The next `getStock()` call for the product will bypass the cache, read the updated `inventory` value, and re-populate `stockCache` with the current stock.

**Alternatively** (write-through instead of invalidate):
```javascript
inventory[item.id] -= item.quantity;
const newStock = inventory[item.id];
stockCache[item.id] = { value: newStock, ts: Date.now() };
```

Write-through is slightly better: it immediately serves the correct value without a cache miss. Either approach stops the stale-read propagation.

---

### Change 2 — Per-product serialization lock

The cache fix narrows the TOCTOU window but does not eliminate it. A per-product promise lock serializes concurrent `reserveInventory` calls for the same product:

```javascript
// Add above reserveInventory():
const locks = {};

function withProductLock(productId, fn) {
  const prev = locks[productId] || Promise.resolve();
  const next = prev.then(fn);
  locks[productId] = next.catch(() => {}); // don't let errors block future callers
  return next;
}
```

Then wrap the per-item block inside `reserveInventory`:

```javascript
for (const item of items) {
  await withProductLock(item.id, async () => {
    // ... existing read → check → sleep → decrement logic ...
  });
}
```

This ensures only one coroutine at a time executes the read-check-decrement sequence per product. Because Node.js is single-threaded, this promise-chain lock is sufficient without a native mutex.

---

## Files to Change

| File | Change |
|---|---|
| `src/services/inventory-nearmiss.js` | Add `delete stockCache[item.id]` (or write-through) after line 64 |
| `src/services/inventory-nearmiss.js` | Add `withProductLock` helper and wrap per-item block |

`inventory.js` (canonical) also needs the per-product lock (Change 2 only — no cache to invalidate), but is not active in the current production pod.

---

## Why Not More Changes

- No changes to `nearmiss-loader.js` — the monkey-patch mechanism is not the bug; the bug is in the code it loads.
- No changes to routes, checkout, or server — the race is fully contained in `inventory-nearmiss.js`.
- No cluster changes — this is a pure code fix; rolling restart of `ecommerce-api` deploys it.

---

## Verification

After deploying, observe in ClickHouse:
```sql
SELECT count() FROM otel_logs
WHERE Timestamp >= now() - INTERVAL 5 MINUTE
  AND mapContains(LogAttributes, 'exception.type')
  AND LogAttributes['exception.type'] = 'StockMismatchError';
```
Expected: count drops to 0 within one TTL cycle (5 seconds) of pod restart.
