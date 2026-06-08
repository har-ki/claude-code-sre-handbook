# Incident Investigation: ecommerce-api | StockMismatchError
**Fingerprint:** `e2836e74` | **Date:** 2026-06-04 | **Investigator:** SRE Agent

---

> **Memory:** Prior finding loaded from `/tmp/nearmiss-capture/memory-store/incidents/e2836e74.md`

---

## Prior Finding (Quoted)

### Root Cause (from memory)
> `reserveInventory()` in `otel-demo/ecommerce/backend/src/services/inventory.js` has a TOCTOU race condition across lines 39–55. The function reads stock via `await getStock(item.id)` (5 ms simulated DB delay), validates `currentStock >= item.quantity`, then sleeps 50–150 ms for "business rule validation," and only then decrements `inventory[item.id]`. Because Node.js yields control at every `await`, multiple concurrent coroutines can all read `currentStock = 5`, all pass the pre-decrement check, and all proceed to decrement — driving stock negative. Product 7 (Ceramic Plant Pot) is uniquely affected because it is initialized with only 5 units while all other products have 50; under load from 3 concurrent load-generator pods requesting quantity 2, the race window (55–155 ms) is wide enough to exhaust product 7's stock within seconds of startup.

### Fix Pattern (from memory)
> Introduce a per-product promise-chain mutex (`acquireLock(productId)`) using no external dependencies. Add a module-scoped `locks` object and a 6-line `acquireLock` helper immediately after the `inventory` declaration. Before the `getStock` call for each item, acquire the lock; release it in a `finally` block after the decrement.

---

## Memory Match Assessment

**MATCH — with one important difference.**

The prior finding references `services/inventory.js`. The pod is actually running `services/inventory-nearmiss.js`, loaded via `src/nearmiss-loader.js` (which monkey-patches `require()` to redirect `inventory.js` → `inventory-nearmiss.js`). The TOCTOU mechanism is **identical** in `inventory-nearmiss.js` — same race window, same guard structure, same product 7 low-stock setup.

The prior finding's root cause analysis is accurate in every material respect.

---

## Pod Health

```
NAME                            READY   STATUS    RESTARTS   AGE
ecommerce-api-57db6bbd9-tcwxw   1/1     Running   0          40m
load-generator-9c744b49-mt48z   1/1     Running   2          40m
load-generator-9c744b49-v4khw   1/1     Running   0          39m
load-generator-9c744b49-x9jjz   1/1     Running   0          39m
```

- **Pod command:** `node -r ./src/instrumentation.js src/nearmiss-loader.js`
- **INVENTORY_VARIANT:** `nearmiss`
- **3 load-generator pods** running concurrently (confirming concurrent load scenario from prior finding)
- No crashes or restart storms — error is application-level, not infrastructure

---

## Error Timeline (ClickHouse — last 15 minutes)

| Minute (UTC)     | Errors | Total | Error Rate |
|-----------------|--------|-------|------------|
| 20:09           | 71     | 142   | 50%        |
| 20:08           | 122    | 244   | 50%        |
| 20:07           | 119    | 238   | 50%        |
| 20:06           | 123    | 246   | 50%        |
| 20:05           | 126    | 252   | 50%        |
| 20:04           | 128    | 256   | 50%        |
| 20:03           | 119    | 238   | 50%        |
| 20:02           | 125    | 250   | 50%        |
| 20:01           | 119    | 238   | 50%        |
| 20:00           | 118    | 236   | 50%        |

**Sustained ~50% error rate** since ~19:54 UTC (first full minute visible). The error rate is perfectly stable — no transient spike, no recovery — consistent with a permanent race condition where stock depletes and never recovers (in-memory store, no restocking).

---

## Exception Details (ClickHouse — top errors, last 15 minutes)

| exc_type | exc_message | count |
|----------|-------------|-------|
| (empty)  | (empty)     | 1807  |
| Error    | Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available **-3** | 1032 |
| Error    | Insufficient stock for product 2 (Smart Watch): requested 1, available 0 | 89 |
| Error    | Insufficient stock for product 5 (Denim Jeans): requested 1, available 0 | 78 |
| Error    | Insufficient stock for product 4 (Cotton T-Shirt): requested 1, available 0 | 77 |
| Error    | Insufficient stock for product 8 (LED Desk Lamp): requested 1, available 0 | 77 |
| Error    | Insufficient stock for product 6 (Running Shoes): requested 1, available **-2** | 68 |

**Key observation:** Product 7 stock is reported as **-3** and product 6 as **-2** — stock went negative. This is the smoking gun for the TOCTOU race: the guard check (`currentStock < item.quantity`) passed for multiple concurrent coroutines, all of which then decremented an already-exhausted inventory.

The 1807 empty-exc_type row consists of INFO-level success logs (reserved items) and the explicit `logger.emit()` calls for `StockMismatchError` (which use a custom attributes dict — the logger emit path rather than span auto-instrumentation).

---

## Root Cause Analysis

### File in use
`otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js` (loaded via `nearmiss-loader.js`, replacing `inventory.js` at runtime via `Module._resolveFilename` hook).

### The TOCTOU race in `inventory-nearmiss.js`

```
Line 48:  const currentStock = await getStock(item.id);   // READ — yields to event loop
Line 51:  if (currentStock < item.quantity) { throw ... }  // GUARD — passes for all concurrent readers
Line 62:  await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100)); // 50–150ms SLEEP — race window
Line 64:  inventory[item.id] -= item.quantity;             // DECREMENT — happens N times
Line 67:  if (newStock < 0) { ... throw StockMismatchError ... }  // POST-DECREMENT CHECK (too late)
```

**Mechanism:**
1. Three load-generator pods fire checkout requests concurrently.
2. Multiple `reserveInventory()` coroutines call `getStock(7)` in near-simultaneous fashion.
3. The `stockCache` in `inventory-nearmiss.js` (5-second TTL) means cached reads take only 1ms — making the race window even easier to hit than the 5ms DB-read path.
4. All coroutines read `currentStock = 5`, all pass the guard (`5 >= 2`), all enter the 50–150ms business-rule sleep.
5. All coroutines proceed to `inventory[7] -= 2` — if 3 coroutines race, final stock = 5 - 6 = **-1** minimum, matching observed `-3`.
6. Post-decrement check fires `StockMismatchError` and logs it; the error propagates to the checkout route.

**Why product 7 is most affected:** Initialized with 5 units vs. 50 for all others. With 3 pods requesting quantity 2 per checkout, product 7 exhausts within the very first concurrent batch. Products 2, 4, 5, 6, 8, etc. show 0 or negative stock too — they've been depleted over time by the same race (just slower, starting from 50 units).

**The `stockCache` aggravation:** `inventory-nearmiss.js` adds a read-through cache not present in the canonical `inventory.js`. Cached reads resolve in 1ms (vs. 5ms), slightly widening the window where multiple coroutines read the same stale cached value before any decrement is reflected.

---

## Confidence Level

**HIGH (95%).**

- Stock going negative (`-3`, `-2`) is direct empirical proof of the race — not inferred.
- Source code confirms the read-validate-sleep-decrement sequence with no lock.
- 3 concurrent load-generators provide the concurrent request pressure required to trigger the race.
- Prior finding matches observed mechanism exactly (differing only on file name, which is explained by the module loader redirect).

---

## Recommended Fix

Per prior finding: add a per-product promise-chain mutex in `inventory-nearmiss.js`. Before `getStock(item.id)`, acquire `const release = await acquireLock(item.id)`; release in a `finally` block after the decrement at line 64. The `acquireLock` helper chains promises per `productId` key, ensuring the read-check-sleep-decrement sequence is atomic per product without any external dependency.

The `stockCache` should also be invalidated or bypassed within the locked critical section to prevent the cache from serving a stale pre-decrement value to a coroutine that acquires the lock after a previous decrement.
