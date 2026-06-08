# Investigation Findings: ecommerce-api | InventoryValidationError
**Date:** 2026-06-05
**Fingerprint:** `ecommerce-api|InventoryValidationError` (hash: `de61efe2`)
**Exception class:** InventoryValidationError
**Investigator:** SRE Agent (claude-sonnet-4-6)

---

## Memory Status and Validation Classification

**Memory discipline:** Active (similarity mode)
**Prior finding loaded:** hash `e2836e74`, similarity score `0.81`
**Classification:** CONFIRMED — prior finding accurately describes the current incident

The prior finding (e2836e74) identified a TOCTOU race condition in `reserveInventory()` and specified a mutex fix. That fix was **never applied** to the running code. The pod in production is executing the unfixed source as of investigation time (2026-06-05 15:23 UTC).

---

## Error Timeline from ClickHouse

Queried `otel_logs` for `ServiceName = 'ecommerce-api'`, severity ERROR, last 15 minutes.

| Minute (UTC)      | Error Count | Error Type         | Message                                                                                     |
|-------------------|-------------|--------------------|---------------------------------------------------------------------------------------------|
| 2026-06-05 15:15  | 1           | StockMismatchError | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -1 after decrement (was 5 at read time)` |
| 2026-06-05 15:15  | 1           | StockMismatchError | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -3 after decrement (was 5 at read time)` |
| 2026-06-05 15:15  | 1           | Error              | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -1 after decrement (was 5 at read time)` |
| 2026-06-05 15:15  | 1           | Error              | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -3 after decrement (was 5 at read time)` |
| 2026-06-05 15:16  | 64          | Error              | `Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3`           |
| 2026-06-05 15:17  | 64          | Error              | (same)                                                                                      |
| ...               | 64/min      | Error              | (steady-state: stock locked at -3, all new requests rejected)                               |
| 2026-06-05 15:22  | 64          | Error              | (same)                                                                                      |
| 2026-06-05 15:23  | 36          | Error              | (same — in-progress minute at query time)                                                   |

**Key observations:**
- **15:15** — race fires: two `StockMismatchError` log entries at two different negative values (`-1` and `-3`) confirm multiple concurrent coroutines all passed the pre-decrement check when `currentStock = 5`, then all decremented, driving stock to -3.
- **15:16 onward** — stock is permanently stuck at -3; every subsequent checkout attempt for product 7 fails immediately at the guard check with `available -3`.
- Error rate is constant at **~64 errors/min** (~1 per second) — matches three concurrent load-generator pods continuously retrying.

---

## Kubernetes Pod Health

```
NAME                             READY   STATUS    RESTARTS
ecommerce-api-7c7f4fd679-cd64t   1/1     Running   0          (8m old)
load-generator-9c744b49-wckz8    1/1     Running   0
load-generator-9c744b49-wdmvq    1/1     Running   0
load-generator-9c744b49-xff2t    1/1     Running   2 (8m ago)
```

- API pod is healthy, no crashes, no restarts — this is an application-level bug, not a platform issue.
- Three load-generator pods are running concurrently, consistent with the load profile that triggers the race.
- `kubectl exec -n ecommerce deploy/ecommerce-api -- cat /proc/1/cmdline` → `npm start` — standard startup, no custom entrypoint override.

---

## Root Cause Analysis

**File:** `otel-demo/ecommerce/backend/src/services/inventory.js`
**Function:** `reserveInventory()`, lines 28–111

### TOCTOU Race Condition (unchanged from prior finding e2836e74)

The race window in `reserveInventory()` is unchanged. The critical path per item:

```
Line 39: const currentStock = await getStock(item.id);  // 5ms simulated DB delay — yields event loop
Line 42: if (currentStock < item.quantity) { throw }    // guard check — passes when currentStock=5
Line 53: await new Promise(r => setTimeout(r, 50+rand*100)); // 50–150ms delay — yields event loop AGAIN
Line 55: inventory[item.id] -= item.quantity;           // decrement — no lock held
```

Because Node.js yields control at every `await`, three concurrent coroutines can all:
1. Read `currentStock = 5` (line 39)
2. Pass the guard check `5 >= 2` (line 42)
3. Wait 50–150ms each (line 53) — all three coroutines run their waits concurrently
4. All three then decrement: `5 - 2 = 3`, `3 - 2 = 1`, `1 - 2 = -1`... except since inventory is shared in-memory and decrements happen in sequence after the yield, the final value is `5 - (3 × 2) = -1` or worse `-3` depending on read ordering.

### Why Product 7 is uniquely affected

Product 7 (`Ceramic Plant Pot`) is initialized with `stock: 5` (line 17). All other products have `stock: 50`. Under a load of 3 concurrent requests each requesting `quantity: 2`, the race window of 55–155 ms is wide enough to exhaust product 7's stock within seconds of startup. Products with 50 units survive many race rounds before going negative.

### The fix from prior finding was NOT applied

The prior finding (e2836e74) recommended introducing a per-product promise-chain mutex (`acquireLock(productId)`). Inspection of the live source confirms this fix is absent — there is no `locks` object, no `acquireLock` helper, and the `await getStock()` call has no preceding lock acquisition.

---

## Confidence Level

**HIGH (95%)**

- ClickHouse data shows the exact `StockMismatchError` race signature at 15:15 (stock read as 5, final value -3) followed by immediate steady-state rejection — exactly matching the prior finding's predicted failure mode.
- Source code read from the live repo confirms the unfixed TOCTOU pattern at lines 39–55.
- Pod health is clean — no crashes, no image pull errors — ruling out infrastructure causes.
- The only discrepancy between prior finding and current observation: prior hash `e2836e74` vs current `de61efe2`. This is a fingerprint hash difference (likely from a slightly different exception message format or service fingerprinting key), not a substantive difference in the underlying bug.

---

## Prior Finding vs Current Observation

| Dimension                     | Prior Finding (e2836e74)                             | Current Observation (de61efe2)                        | Match? |
|-------------------------------|------------------------------------------------------|-------------------------------------------------------|--------|
| Affected service              | ecommerce-api                                        | ecommerce-api                                         | YES    |
| Affected product              | Product 7, Ceramic Plant Pot, initial stock 5        | Product 7, Ceramic Plant Pot, stock at -3             | YES    |
| Race mechanism                | TOCTOU in reserveInventory(), 55–155ms window        | Same — getStock() + 50–150ms sleep + decrement        | YES    |
| Load trigger                  | 3 concurrent load-generator pods, qty 2              | 3 concurrent load-generator pods confirmed            | YES    |
| Fix applied?                  | Recommended mutex (acquireLock per productId)        | NOT APPLIED — unfixed code in production              | N/A    |
| Error message                 | `Insufficient stock...available -3`                  | `Insufficient stock...available -3`                   | YES    |
| StockMismatchError at genesis | Expected (race detection log)                        | Confirmed at 15:15 with values -1 and -3              | YES    |

**Verdict:** Prior finding **matches** current observation in every substantive dimension. The incident is a recurrence of the same unfixed bug.

---

## Recommended Fix

Apply the mutex fix from prior finding e2836e74 to `otel-demo/ecommerce/backend/src/services/inventory.js`:

1. Add a module-scoped `locks` object after line 19: `const locks = {};`
2. Add a 6-line `acquireLock(productId)` helper that chains onto `locks[productId]`
3. In the `for` loop, acquire the lock before `getStock()` (line 39) and release in a `finally` after the decrement (line 55)

This makes the read-check-decrement sequence atomic per product, eliminating the TOCTOU window with no external dependencies.
