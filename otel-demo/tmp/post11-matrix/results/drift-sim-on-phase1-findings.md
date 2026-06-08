# Investigation Findings: ecommerce-api | InventoryValidationError

**Fingerprint:** `ecommerce-api|InventoryValidationError`
**Fingerprint hash:** `de61efe2`
**Investigation date:** 2026-06-05 15:26 UTC
**Investigator:** SRE Agent (Claude Sonnet 4.6)

---

## Memory Status & Validation Classification

> **Validation: VALIDATED** — prior finding matches current evidence because:
> 1. ClickHouse logs show `StockMismatchError` with the exact message `"stock for product 7 (Ceramic Plant Pot) is -3 after decrement (was 5 at read time)"` — this is precisely the TOCTOU fingerprint described in the prior finding.
> 2. The deployed source code at `inventory.js:39–55` is structurally identical to what the prior finding described: `getStock()` (5 ms delay) → stock check → 50–150 ms business rule sleep → decrement. No mutex, no lock.
> 3. Product 7 (Ceramic Plant Pot) is exclusively the high-frequency victim (700/738 errors), consistent with its unique initial stock of 5 vs. 50 for all other products.

**Prior finding (matched hash e2836e74, score 0.81) is used as the primary hypothesis and confirmed by fresh evidence below.**

---

## Error Timeline from ClickHouse

Query: `otel_logs` for `ecommerce-api`, `SeverityText IN ('ERROR','Error','error')`, last 15 minutes.

| Minute (UTC) | Error Count |
|---|---|
| 15:15 | 4 |
| 15:16 | 64 |
| 15:17 | 64 |
| 15:18 | 64 |
| 15:19 | 64 |
| 15:20 | 64 |
| 15:21 | 64 |
| 15:22 | 64 |
| 15:23 | 68 |
| 15:24 | 75 |
| 15:25 | 72 |
| 15:26 | 73 |

**Pattern:** Errors spike from 4 to 64/min at 15:16 (within seconds of 3 load-generator pods reaching steady-state concurrency) and remain constant/slightly increasing. The steady 64/min rate correlates with the 3-pod load-generator firing concurrent checkout requests.

---

## Exception Breakdown

| Exception Type | Message | Count |
|---|---|---|
| `Error` | `Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3` | 700 |
| `Error` | `Insufficient stock for product 9 (Throw Blanket): requested 1, available 0` | 17 |
| `Error` | `Insufficient stock for product 4 (Cotton T-Shirt): requested 1, available 0` | 8 |
| `Error` | `Insufficient stock for product 11 (Winter Jacket): requested 1, available 0` | 6 |
| `Error` | `Insufficient stock for product 1 (Wireless Headphones): requested 1, available 0` | 3 |
| `Error` | `Insufficient stock for product 3 (Laptop Stand): requested 1, available 0` | 2 |
| `StockMismatchError` | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -3 after decrement (was 5 at read time)` | 2 |
| `StockMismatchError` | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -1 after decrement (was 5 at read time)` | 2 |

**Key signal:** `StockMismatchError` entries reveal the race directly — the stock read value was 5, but the final value after decrement was -1 or -3, proving 2–4 coroutines passed the check simultaneously before any decrement landed.

The "available -3" in the primary `Error` message confirms stock was already negative by the time later requests ran `getStock()`, meaning the race drove stock deeply negative before any circuit-breaker fired.

---

## Kubernetes Pod Health

```
NAME                             READY   STATUS    RESTARTS
ecommerce-api-7c7f4fd679-cd64t   1/1     Running   0          (11m)
load-generator-9c744b49-wckz8    1/1     Running   0          (10m)
load-generator-9c744b49-wdmvq    1/1     Running   0          (10m)
load-generator-9c744b49-xff2t    1/1     Running   2 (11m)    (11m)
```

- Pod is healthy (1/1, 0 restarts). The issue is a **logic bug**, not an infrastructure failure.
- 3 load-generator pods are running concurrently — this is the concurrency source driving the race.
- One load-generator pod has 2 restarts at 11m old — likely crashed before stabilizing; now steady.
- Process running in pod: `npm start` (confirmed via `/proc/1/cmdline`).
- Image: `ecommerce-api:latest` (sha `adbde248`).

---

## Source Code Analysis

**File:** `otel-demo/ecommerce/backend/src/services/inventory.js`

```
inventory[7] = 5   // only 5 units, all others = 50

async function getStock(productId) {
  await new Promise(resolve => setTimeout(resolve, 5));  // line 23: yields control
  return inventory[productId];
}

async function reserveInventory(items) {
  for (const item of items) {
    const currentStock = await getStock(item.id);       // line 39: reads stock
    // ... stock check at line 42 ...
    await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100)); // line 53: 50-150ms yield
    inventory[item.id] -= item.quantity;                // line 55: decrement
  }
}
```

**TOCTOU race window:**
1. Coroutine A calls `getStock(7)` → reads `inventory[7] = 5`, yields for 5 ms.
2. Coroutines B and C also call `getStock(7)` during A's yield → all read `currentStock = 5`.
3. All three pass `currentStock >= item.quantity` check (5 >= 2).
4. All three enter the 50–150 ms sleep concurrently (Node.js yields at every `await`).
5. All three execute `inventory[7] -= 2` sequentially (no lock), producing `5 → 3 → 1 → -1`.
6. The post-decrement check at line 58 catches `newStock < 0` and fires `StockMismatchError`.
7. Subsequent requests then read `currentStock = -3` and throw `InventoryValidationError` with `available -3`.

**The `inventory-nearmiss.js` variant** (present in the repo but not deployed) introduces a `stockCache` with 5-second TTL. This would make the race **worse**: the stale value of 5 would be served from cache for 5 seconds to all concurrent requests, eliminating even the 5 ms DB-read delay that partially serializes reads in the current version.

---

## Root Cause Analysis

**Root cause:** TOCTOU (Time-of-Check to Time-of-Use) race condition in `reserveInventory()` at `inventory.js:39–55`.

The function is not atomic. Three concurrent coroutines (one per load-generator pod) can all read `stock = 5`, all pass the check, and all decrement — driving stock to -1 or -3. Node.js's event-loop concurrency model means every `await` is a preemption point; no external thread safety is needed to trigger this.

**Why product 7 specifically:** Initial stock of 5 (vs. 50 for all other products). Under a 3-pod load generating requests for quantity 2, the race exhausts product 7's stock in <1 second of sustained concurrency. Products with stock 50 experience the same race but have a much larger buffer before going negative, and likely recovered before the observation window.

**Fix pattern (per prior finding):** Introduce a per-product promise-chain mutex (`acquireLock(productId)`) using a module-scoped `locks` object. Acquire lock before `getStock()`, release in `finally` after decrement. This makes read-check-decrement atomic per product ID.

---

## Confidence Level

**HIGH (95%).**

- The `StockMismatchError` log entries directly capture the race: `was 5 at read time` vs. `is -3 after decrement`.
- Source code structure perfectly matches the race pattern at the exact lines identified in the prior finding.
- Error rate, error distribution, and product-7 concentration are all consistent with the TOCTOU hypothesis.
- No other explanation (network partition, OOM, config drift, external dependency) is consistent with the evidence.

---

## Comparison to Prior Finding

| Dimension | Prior Finding (e2836e74) | Current Observation |
|---|---|---|
| Root cause | TOCTOU in `reserveInventory()` | Confirmed — identical code structure |
| Affected lines | 39–55 | Confirmed — `getStock` at 39, sleep at 53, decrement at 55 |
| Affected product | Product 7, Ceramic Plant Pot | Confirmed — 700/738 errors on product 7 |
| Mechanism | Multiple coroutines pass stock check during 50–150ms sleep | Confirmed via `StockMismatchError` events |
| Stock value at race time | `currentStock = 5` | Confirmed: `was 5 at read time` in logs |
| Fix pattern | Promise-chain mutex per productId | Not yet applied — race is still live |

**Prior finding is fully corroborated. No contradictions found.**

---

## Recommendations

1. **Immediate:** Apply the per-product mutex fix to `inventory.js` as described in the prior finding (6-line `acquireLock` helper, wrap lines 39–55).
2. **Do not deploy `inventory-nearmiss.js`:** The stale read-through cache would amplify the race, not mitigate it.
3. **Validation:** After the fix, confirm `StockMismatchError` count drops to zero and `inventory[7]` stabilizes at `≥ 0` under load.
