# Investigation Findings: ecommerce-api | StockMismatchError
**Fingerprint:** `e2836e74`
**Date:** 2026-06-04
**Investigator:** SRE Agent (warm run)

---

> **Memory:** Prior finding loaded from `/tmp/watcher-memory-capture/memory-store/incidents/e2836e74.md`

### Quoted Prior Finding

**Root Cause (from memory):**
> `reserveInventory()` in `otel-demo/ecommerce/backend/src/services/inventory.js` has a TOCTOU race condition across lines 39–55. The function reads stock via `await getStock(item.id)` (5 ms simulated DB delay), validates `currentStock >= item.quantity`, then sleeps 50–150 ms for "business rule validation," and only then decrements `inventory[item.id]`. Because Node.js yields control at every `await`, multiple concurrent coroutines can all read `currentStock = 5`, all pass the pre-decrement check, and all proceed to decrement — driving stock negative. Product 7 (Ceramic Plant Pot) is uniquely affected because it is initialized with only 5 units while all other products have 50; under load from 3 concurrent load-generator pods requesting quantity 2, the race window (55–155 ms) is wide enough to exhaust product 7's stock within seconds of startup.

**Fix Pattern (from memory):**
> Introduce a per-product promise-chain mutex (`acquireLock(productId)`) using no external dependencies. Before the `getStock` call for each item, acquire the lock; release it in a `finally` block after the decrement. This makes the read-check-decrement sequence atomic per product, eliminating the TOCTOU window. The lock is keyed by `productId` so unaffected products (1–6, 8–12) continue processing concurrently. All existing span attributes, logger calls, and error shapes remain unchanged — the only structural change is wrapping lines 39–85 in `const release = await acquireLock(item.id); try { ... } finally { release(); }` and adding the ~6-line `acquireLock` helper after the `inventory` declaration.

---

## Error Timeline (ClickHouse — last 15 minutes)

| Minute (UTC)        | Error Count | Exception Type     | Message                                                                 |
|---------------------|-------------|--------------------|-------------------------------------------------------------------------|
| 2026-06-04 18:05:00 | 40          | Error              | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 |
| 2026-06-04 18:04:00 | 60          | Error              | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 |
| 2026-06-04 18:03:00 | 68          | Error              | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 |
| 2026-06-04 18:02:00 | 60          | Error              | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 |
| 2026-06-04 18:01:00 | 68          | Error              | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 |
| 2026-06-04 18:00:00 | 64          | Error              | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 |
| 2026-06-04 17:59:00 | 48          | Error              | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 |
| 2026-06-04 17:59:00 | 1           | StockMismatchError | Inventory inconsistency: stock for product 7 is -3 after decrement (was 5 at read time) |
| 2026-06-04 17:59:00 | 1           | Error              | Inventory inconsistency: stock for product 7 is -3 after decrement (was 5 at read time) |
| 2026-06-04 17:59:00 | 1           | StockMismatchError | Inventory inconsistency: stock for product 7 is -1 after decrement (was 5 at read time) |
| 2026-06-04 17:59:00 | 1           | Error              | Inventory inconsistency: stock for product 7 is -1 after decrement (was 5 at read time) |

**Total errors observed:** ~413 across 7 minutes (sustained ~55–68/min).
**Only affected product:** Product 7 — Ceramic Plant Pot (`inventory[7] = 5`, all others = 50).
**Stock floor reached:** `-3` (indicating 3 over-decrements beyond zero).

---

## Kubernetes Pod Health

**Namespace:** `ecommerce`

| Pod | Status | Restarts |
|-----|--------|----------|
| ecommerce-api-7c7f4fd679-l994d | Running 1/1 | 0 |
| load-generator-9c744b49-d6gq8 | Running 1/1 | 0 |
| load-generator-9c744b49-dd2jg | Running 1/1 | 0 |
| load-generator-9c744b49-rbdlr | Running 1/1 | 2 (restarted ~7m ago) |

- `ecommerce-api` pod is **healthy** — no restarts, no crash loop.
- **3 load-generator replicas** are running concurrently against the API, consistent with the TOCTOU race scenario described in prior finding.
- One load-generator pod had 2 prior restarts (likely startup initialization, not related to the stock error).

---

## Root Cause Analysis

**Confirmed TOCTOU race condition in `reserveInventory()` — corroborated by prior finding.**

The race window in `inventory.js` is:

```
Line 39:  const currentStock = await getStock(item.id);   // 5ms DB delay — yields control
Line 42:  if (currentStock < item.quantity) { ... }        // check passes: 5 >= 2
Line 53:  await new Promise(resolve => setTimeout(...));   // 50–150ms "business rules" — yields again
Line 55:  inventory[item.id] -= item.quantity;             // DECREMENT (too late — others already passed check)
Line 58:  if (newStock < 0) { ... throw StockMismatchError }
```

**Why only product 7:** `inventory[7] = 5` (line 17) while all other products start at 50. With 3 concurrent load-generators each requesting quantity 2, the 50–150ms yield window (line 53) allows all 3 coroutines to simultaneously read `currentStock = 5`, pass the `>= 2` check, and then all decrement — producing `5 - 2 - 2 - 2 = -1` or `5 - 2 - 2 - 2 - 2... = -3`.

**Sequence of events from logs:**
1. At 17:59 — first `StockMismatchError` fired: stock reached `-1` then `-3` after concurrent decrements.
2. From 17:59 onwards — 48–68 `Insufficient stock` errors per minute as the in-memory stock is now permanently `-3` and all subsequent requests fail the pre-decrement check.
3. The error rate is sustained and consistent (no recovery) because the in-memory store has no reset mechanism and the pods have not restarted.

---

## Confidence Level

**HIGH (95%)** — Prior memory finding matches exactly:
- Same product (Product 7 / Ceramic Plant Pot)
- Same mechanism (TOCTOU at lines 39–55)
- Same stock floor observed (`-3` in logs, consistent with 3-pod concurrent decrement of initial stock 5)
- 3 load-generator pods confirmed running (exact scenario described in memory)
- Source code confirms the race window is unchanged — no mutex present

**Fix:** Apply `acquireLock(productId)` mutex per prior finding's Fix Pattern — wrap lines 39–85 in `inventory.js` with per-product lock acquire/release.
