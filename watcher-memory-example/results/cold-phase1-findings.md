# Incident Investigation: ecommerce-api | StockMismatchError
**Fingerprint:** `e2836e74`
**Date:** 2026-06-04
**Investigator:** Claude SRE Agent (cold-phase1)

---

> **Memory:** No prior finding for fingerprint e2836e74

---

## Memory Status
**MISS** — No prior resolution recorded for fingerprint `e2836e74`. Fresh investigation performed.

---

## Error Timeline (ClickHouse otel_logs)

| Minute (UTC)       | Errors | Total Logs |
|--------------------|--------|------------|
| 2026-06-04 17:58   | 0      | 8          |
| 2026-06-04 17:59   | 52     | 278        |
| 2026-06-04 18:00   | 64     | 316        |
| 2026-06-04 18:01   | 68     | 332        |
| 2026-06-04 18:02   | 60     | 308        |
| 2026-06-04 18:03   | 24     | 124        |

**Total errors in 15-minute window:** ~268
Errors began 1 minute after pod startup (17:58 start → 17:59 first errors). Load generators immediately drove concurrent requests.

---

## Error Breakdown (Last 15 Minutes)

| exc_type           | exc_message (summary)                                              | product_id | product_name      | count |
|--------------------|--------------------------------------------------------------------|------------|-------------------|-------|
| *(untyped)*        | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3 | —  | —            | 260   |
| StockMismatchError | Inventory inconsistency: stock for product 7 is **-1** after decrement (was 5 at read time) | 7 | Ceramic Plant Pot | 1  |
| *(untyped)*        | Inventory inconsistency: stock for product 7 is **-3** after decrement (was 5 at read time) | — | —            | 1     |
| StockMismatchError | Inventory inconsistency: stock for product 7 is **-3** after decrement (was 5 at read time) | 7 | Ceramic Plant Pot | 1  |
| *(untyped)*        | Inventory inconsistency: stock for product 7 is **-1** after decrement (was 5 at read time) | — | —            | 1     |

**All errors are isolated to product ID 7 (Ceramic Plant Pot).**

---

## Kubernetes Pod Health

- **ecommerce-api pod:** `1/1 Running`, **0 restarts**, healthy
- **load-generator pods:** 3 replicas running; 1 pod had 2 restarts (load-generator, not API)
- **No OOM kills, no resource pressure** on ecommerce-api
- Pod started at `10:58:37 -0700` (17:58 UTC) — errors began within 60 seconds as load generators engaged

---

## Root Cause Analysis

### TOCTOU Race Condition in `reserveInventory()`

**File:** `otel-demo/ecommerce/backend/src/services/inventory.js`

The `reserveInventory()` function has a classic **Time-of-Check to Time-of-Use (TOCTOU)** race condition across three sequential async operations with no locking:

```
Line 39:  const currentStock = await getStock(item.id);  // READ (5ms simulated DB delay)
Line 42:  if (currentStock < item.quantity) { throw ... }  // CHECK
Line 53:  await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100)); // WAIT 50–150ms
Line 55:  inventory[item.id] -= item.quantity;             // WRITE (decrement)
Line 58:  if (newStock < 0) { throw StockMismatchError }  // POST-WRITE GUARD
```

**Race window:** Lines 39–55 span **55–155ms** of async I/O + sleep. During this window, multiple concurrent requests can ALL read `currentStock = 5`, ALL pass the stock check at line 42, and ALL proceed to decrement. With 3 load-generator pods sending requests for quantity 2, two simultaneous requests both read stock=5, both pass, then both decrement: `5 - 2 - 2 = 1` (fine), but three concurrent requests: `5 - 2 - 2 - 2 = -1` (StockMismatchError).

**Why product 7 only:** Product 7 (Ceramic Plant Pot) is initialized with only **5 units** (line 17), while all other products have 50 units. Product 7 is the only SKU that can be exhausted under concurrent load within the window.

**In-memory state:** The `inventory` object is a plain JS object (line 15) — no atomic operations, no mutex, no database-level row locking. Node.js is single-threaded but `await` yields control, allowing interleaving of multiple concurrent coroutines.

### StockMismatchError vs. "Insufficient stock" split
- **StockMismatchError** (lines 59–85): Fired *after* decrement when `newStock < 0`. This is the named exception class. (2 occurrences with product.id attribute)
- **"Insufficient stock" error** (lines 43–49): Fired *before* decrement when stock is already negative from prior race victims. (260 occurrences — downstream requests hitting stock that's already been driven negative)

The 260 "Insufficient stock" errors are **secondary failures** — they occur after the stock has already been driven below zero by the initial race victims, so every subsequent request for product 7 is rejected.

---

## Confidence Level

**HIGH**

- Error messages explicitly state the race: `"stock for product 7 is -1 after decrement (was 5 at read time)"` — stock was read as 5, validated, then written as negative.
- Code path is unambiguous: no mutex, no atomic compare-and-swap, 50–150ms deliberate sleep between read and write.
- 100% of errors are product 7, which has uniquely low initial stock (5 vs 50 for all others).
- Load generator pods (3 replicas) provide the concurrent request pressure needed to trigger the race.

---

## Evidence Summary

| Evidence | Detail |
|----------|--------|
| Error count (15 min) | 268 total errors |
| Affected product | Product 7 (Ceramic Plant Pot) only |
| Stock read at time of check | 5 |
| Stock after concurrent decrements | -1, -3 |
| Race window | 55–155ms (lines 39–55 of inventory.js) |
| Missing guard | No mutex/lock on read-check-write sequence |
| Pod restarts | 0 (not a crash/OOM issue) |
| Code location | `services/inventory.js:39–85` |

---

## Recommended Fix (read-only finding — no changes applied)

The fix requires making the read-check-write sequence **atomic**:

1. **Short-term:** Use a per-product async mutex (e.g., `async-mutex` npm package) around the read→check→decrement block in `reserveInventory()`.
2. **Long-term:** Move inventory to a real database with `UPDATE inventory SET stock = stock - ? WHERE product_id = ? AND stock >= ?` (atomic compare-and-decrement with row locking).

---

*Investigation completed read-only. No cluster changes made. No commits created.*
