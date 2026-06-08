# Investigation Report: ecommerce-api | StockMismatchError
**Date:** 2026-06-05
**Fingerprint:** `ecommerce-api|StockMismatchError` (hash: `e2836e74`)
**Exception class:** StockMismatchError

---

## Memory Status

**Prior finding loaded:** similarity score 0.80, matched hash `e2836e74`, resolved 2026-06-04.

> **Validation: VALIDATED** — the prior finding matches current evidence exactly. The TOCTOU race condition in `reserveInventory()` is still present in the source code (no mutex introduced), product 7 (Ceramic Plant Pot) is still initialized with 5 units while all other products have 50, and ClickHouse confirms active negative-stock errors beginning at `2026-06-05 15:15:51` — consistent with the same race pattern described in the prior finding.

---

## Error Timeline (ClickHouse `otel_logs`, last 15 minutes)

| Minute (UTC) | Count | Exception Type | Message |
|---|---|---|---|
| 15:15 | 1 | `StockMismatchError` | `stock for product 7 … is -1 after decrement (was 5 at read time)` |
| 15:15 | 1 | `StockMismatchError` | `stock for product 7 … is -3 after decrement (was 5 at read time)` |
| 15:15–15:25 | 634 | `Error` | `Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3` |
| 15:25 | 1 | `Error` | `Insufficient stock for product 9 (Throw Blanket): …` |
| 15:25 | 1 | `Error` | `Insufficient stock for product 4 (Cotton T-Shirt): …` |

**Summary by type (15-minute window):**

| exc_type | count | first_seen | last_seen |
|---|---|---|---|
| `Error` | 634 | 2026-06-05 15:15:51 | 2026-06-05 15:25:33 |
| `StockMismatchError` | 2 | 2026-06-05 15:15:51 | 2026-06-05 15:15:51 |

**Interpretation:** The `StockMismatchError` events (the race being detected post-decrement) appear first at 15:15:51, causing stock to reach -3. All subsequent 634 errors are downstream `Error` (Insufficient stock) as every reservation attempt for product 7 then fails because `available = -3 < 2`.

---

## Kubernetes Pod Health

```
NAME                             READY   STATUS    RESTARTS   AGE
ecommerce-api-7c7f4fd679-cd64t   1/1     Running   0          ~10m
load-generator-9c744b49-wckz8    1/1     Running   0          ~9m
load-generator-9c744b49-wdmvq    1/1     Running   0          ~9m
load-generator-9c744b49-xff2t    1/1     Running   2          ~10m
```

- ecommerce-api: healthy, 0 restarts. Running `npm start`.
- 3 load-generator pods active (one with 2 restarts — transient).

---

## Source Code Analysis

**File:** `otel-demo/ecommerce/backend/src/services/inventory.js`

**Inventory initialization (line 15–19):**
```js
const inventory = {
  1: 50, 2: 50, 3: 50, 4: 50, 5: 50, 6: 50,
  7: 5,      // Ceramic Plant Pot — limited stock
  8: 50, 9: 50, 10: 50, 11: 50, 12: 50,
};
```

**Race condition in `reserveInventory()` (lines 39–55):**
```js
// Line 39: async DB read — yields event loop (5 ms)
const currentStock = await getStock(item.id);          // reads inventory[id]

// Line 42–50: pre-check
if (currentStock < item.quantity) { throw err; }

// Line 53: simulated business rule validation — yields event loop (50–150 ms)
await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

// Line 55: decrement (not atomic with read)
inventory[item.id] -= item.quantity;

// Lines 58–85: post-decrement check (logged as StockMismatchError)
if (newStock < 0) { ... throw err; }
```

**TOCTOU window:** Between `getStock` (line 39) and `inventory[item.id] -= item.quantity` (line 55), there is a 55–155 ms yield window. Multiple concurrent coroutines serving 3 load-generator pods each read `currentStock = 5`, all pass the `< item.quantity` check, and all proceed to decrement — resulting in stock reaching `-3` (3 concurrent decrements of 2 from a base of 5).

**No mutex or locking present.** The prior finding's recommended fix (per-product promise-chain mutex using `acquireLock(productId)`) has **not been applied**.

---

## Root Cause Analysis

The root cause is a **TOCTOU (Time-Of-Check-Time-Of-Use) race condition** in `reserveInventory()` at `inventory.js:39–55`.

1. Node.js's cooperative multitasking yields control at every `await`.
2. The read (`getStock`, line 39) and the write (`inventory[id] -= qty`, line 55) are separated by a 50–150 ms async sleep (line 53).
3. With 3 concurrent load-generator pods making simultaneous reservation requests for product 7 (quantity 2, initial stock 5), multiple coroutines read `stock = 5`, all pass validation, and all decrement — driving stock to `-3`.
4. The `StockMismatchError` is the post-decrement guard at lines 58–85 firing; all subsequent errors are the downstream `available = -3` failures that persist until restart.

**Product 7 is uniquely vulnerable** because its initial stock of 5 is exhausted in a single race window (≥3 concurrent requests × qty 2 > 5), whereas other products with stock 50 survive the same load.

---

## Confidence Level

**High (0.95).** The prior finding described this exact mechanism. Fresh ClickHouse evidence confirms:
- `StockMismatchError` appeared at 15:15:51 with the exact message pattern `"was 5 at read time"` (stock read correctly as 5, written as -1 and -3).
- 634 subsequent downstream errors confirm the race succeeded in depleting stock.
- Source code still contains the unguarded read-check-sleep-write pattern with no mutex.
- 3 active load-generator pods provide the necessary concurrency to trigger the race.

---

## Comparison: Prior Finding vs Current Evidence

| Dimension | Prior Finding (2026-06-04) | Current Evidence (2026-06-05) |
|---|---|---|
| Affected product | Product 7 (Ceramic Plant Pot), stock=5 | Same |
| Race window | 55–155 ms between `getStock` and decrement | Same (line 39 + line 53 + line 55) |
| Concurrency source | 3 load-generator pods, qty=2 | Same (3 pods confirmed) |
| Error type emitted | `StockMismatchError` then downstream `Error` | Same sequence observed in logs |
| Fix applied | Recommended: per-product promise-chain mutex | **Not applied** — no lock code in source |
| Final stock value | -3 | -3 (confirmed: `available -3`) |

**Conclusion:** Prior finding fully corroborated. The fix was not applied between 2026-06-04 and 2026-06-05. The same race is recurring on each fresh pod startup.
