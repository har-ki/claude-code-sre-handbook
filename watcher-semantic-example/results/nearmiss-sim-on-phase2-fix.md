# Phase 2 Fix Proposal — Incident e2836e74

## Summary

**Service:** ecommerce-api
**Fingerprint:** e2836e74
**Date:** 2026-06-05
**Affected file:** `otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js`

---

## Root Cause

`inventory-nearmiss.js` introduces a read-through cache (`stockCache`, TTL = 5 s) on top of the
authoritative in-memory `inventory` object.  After a successful reservation the cache entry is
**never invalidated**, so concurrent requests that arrive within the same 5-second window all
receive the **pre-decrement stock value**.  Combined with the 50–150 ms async delay that simulates
"business rule validation" (line 62), the window is wide enough for several concurrent checkouts to:

1. All read the same cached stock (e.g. `5` for product 7 "Ceramic Plant Pot").
2. All pass the `currentStock < item.quantity` guard.
3. Each decrement `inventory[7]` sequentially → `5 → 3 → 1 → -1`.
4. The post-decrement guard (`newStock < 0`) fires, emitting a `StockMismatchError` log and
   returning HTTP 500.

This is a classic **TOCTOU (Time-of-Check / Time-of-Use)** defect made exploitable by a stale cache.
Product 7 is the near-certain trigger: it starts at only 5 units.

---

## Minimal Fix

In `inventory-nearmiss.js`, add a single line immediately after the decrement to **evict the stale
cache entry** so the next reader is forced to fetch the current (post-decrement) value:

```diff
-        inventory[item.id] -= item.quantity;
+        inventory[item.id] -= item.quantity;
+        delete stockCache[item.id];   // evict stale entry; next read fetches live stock
         const newStock = inventory[item.id];
```

**Why this is sufficient:**
The cache is a read-optimisation only. Evicting after every write means each concurrent request
that arrives after a reservation will get a fresh read of `inventory[item.id]` (≤ 5 ms simulated
latency) rather than the cached pre-decrement value, closing the TOCTOU window.

**Why nothing else needs changing:**
- The canonical `inventory.js` (no cache) is already correct.
- The checkout route, load generator, and OTel instrumentation are unaffected.
- No schema changes, no restart of dependent services.

---

## Diff

```diff
--- a/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js
+++ b/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js
@@ -62,6 +62,7 @@ async function reserveInventory(items) {
         // Validate inventory policies and apply business rules
         await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

         inventory[item.id] -= item.quantity;
+        delete stockCache[item.id];
         const newStock = inventory[item.id];
```

---

## Verification

After applying the fix, run concurrent load targeting product 7 and confirm:

- No `StockMismatchError` logs in `otel_logs`.
- `stock.after` never goes negative in span attributes.
- HTTP 409 ("Insufficient stock") is returned correctly once stock reaches 0, not HTTP 500.
