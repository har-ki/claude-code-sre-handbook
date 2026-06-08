# Phase 2 Fix Proposal — Incident e2836e74

## Summary

**Service:** ecommerce-api
**Fingerprint:** `e2836e74`
**Date:** 2026-06-05
**Variant in use:** `inventory-nearmiss.js` (loaded via `nearmiss-loader.js`)

---

## Root Cause

The `inventory-nearmiss.js` module introduces a read-through cache (`stockCache`, 5 s TTL) in `getStock()`. The reservation flow is:

1. Read stock via cache (may be up to 5 s stale)
2. Check `currentStock >= item.quantity` — passes
3. Await 50–150 ms simulated business-rule delay
4. Decrement `inventory[item.id] -= item.quantity`
5. Check `newStock < 0` — throws `StockMismatchError`

This is a **TOCTOU (Time-Of-Check / Time-Of-Use)** race. Two concurrent checkout requests for the same low-stock product (e.g. Ceramic Plant Pot, initial stock = 5) both read the cached value, both pass the guard at step 2, both sleep through step 3, and both decrement — driving stock negative and throwing `StockMismatchError`.

The stale cache amplifies the window: all requests within a 5 s burst see identical stock, so the race is near-guaranteed under moderate load.

---

## Minimal Fix

Re-read the live inventory value **after** the async delay, immediately before decrementing. If stock is no longer sufficient at write time, abort with a retriable error rather than letting the decrement proceed into negative territory.

**File:** `src/services/inventory-nearmiss.js`

```js
// After the business-rule delay, re-validate against live inventory
// before writing to close the TOCTOU window introduced by the cache.
const liveStock = inventory[item.id];   // direct read, no cache
if (liveStock < item.quantity) {
  const err = new Error(
    `Stock changed between check and reserve for product ${item.id} ` +
    `(${productName}): available ${liveStock}, requested ${item.quantity}`
  );
  span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
  span.recordException(err);
  throw err;
}
inventory[item.id] -= item.quantity;
```

Insert this block **between** the 50–150 ms delay (`await new Promise(...)`) and the decrement line (`inventory[item.id] -= item.quantity`) at line 64.

---

## Why This Is Sufficient

- No architectural change required.
- The cache is still used for the read-heavy `getStock()` path (product listing, etc.).
- The added guard converts a silent negative-stock corruption into an explicit, observable error with a clear message — which callers can retry.
- The `newStock < 0` post-decrement check (line 67) becomes a last-resort safety net rather than the primary guard.

---

## What Was NOT Changed

- `nearmiss-loader.js` module-patching mechanism — not the source of the bug.
- `inventory.js` canonical module — already correct (no cache, no race window).
- No changes to routes, server, or instrumentation.
