# Investigation Findings: ecommerce-api StockMismatchError
**Fingerprint:** `ecommerce-api|StockMismatchError` (`e2836e74`)
**Date:** 2026-06-05
**Investigator:** SRE agent (automated)
**Output path note:** Written to `otel-demo/tmp/...` — `/tmp` write was blocked by session permissions.

---

## Memory Status and Validation

**Memory loaded:** Yes — prior finding for hash `e2836e74`, similarity score 0.80, captured 2026-06-04.

**Validation classification:** PARTIAL MATCH — VARIANT ACTIVE

The prior finding correctly identifies the core TOCTOU race mechanism in `reserveInventory()`. However, the currently running code is **not** the canonical `inventory.js` described in the prior finding. The pod is running `inventory-nearmiss.js` via the `nearmiss-loader.js` module intercept, which introduces two additional behaviors not present in the prior analysis:

1. A **read-through stock cache** (5-second TTL) that amplifies the race window
2. A **post-decrement inconsistency detector** that emits the `StockMismatchError` fingerprint after stock goes negative

The prior finding's fix pattern (mutex) remains valid and would resolve the race, but the prior finding did not account for the cache amplifier introduced in the near-miss variant.

---

## Pod State

```
NAME                             READY   STATUS    RESTARTS   AGE
ecommerce-api-66796bf6bc-qr2sq   1/1     Running   0          48s   (at query time)
```

- **Image:** `ecommerce-api:latest`
- **Entrypoint:** `node -r ./src/instrumentation.js src/nearmiss-loader.js`
- **Env:** `INVENTORY_VARIANT=nearmiss`
- **Restarted at:** `2026-06-05T08:28:35-07:00` (= 15:28:35 UTC) — 48s before first query

The pod was freshly restarted at the start of the incident window. Every restart resets the in-memory `inventory` store, resetting product 7 back to 5 units. This restart pattern causes the race to recur on each pod restart.

---

## Error Timeline (ClickHouse `otel_logs`, last 15 minutes)

| Minute (UTC) | Error count | Sample message |
|---|---|---|
| 15:15 | 4 | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -1 after decrement (was 5 at read time)` |
| 15:16–15:25 | 64–75/min | `Checkout failed: ... Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3` |
| 15:26–15:28 | 93–98/min | `Checkout failed: ... available 0` — products 4,5,9,11,12 |
| 15:29 | 12 | `Checkout failed: ... available -19` — product 7 |

**Phase 1 (15:15):** Race fires within seconds of startup. Four concurrent coroutines all read the cached `currentStock = 5`, all pass the pre-check (`5 >= 2`), all decrement, driving stock to `5 - (4×2) = -3`. The post-decrement detector (lines 67–94 of `inventory-nearmiss.js`) catches the first crossing below zero (`is -1`) and emits the `StockMismatchError` fingerprint.

**Phase 2 (15:16–15:25):** Stock is now -3. Subsequent requests hit the pre-check with the cached or live -3 value and throw `Insufficient stock for product 7 (Ceramic Plant Pot): requested 2, available -3`. These are NOT `StockMismatchError` — they are caught before decrement. Error rate stabilizes at ~64/min (matching load-generator throughput targeting product 7).

**Phase 3 (15:26–15:28):** Load diversifies. Products 4,5,9,11,12 show `available 0` — this is **legitimate depletion** (50 units × load), not a race condition. These products have sufficient initial stock that the TOCTOU window doesn't produce negative values — concurrent reads decrement to exactly 0 and the next request sees 0.

**Phase 4 (15:29):** Pod restart propagates the fresh `inventory` object. Product 7 resets to 5. Race fires again, this time stock hits -19 (more concurrent coroutines due to warmed load generator). Fingerprinted `StockMismatchError` would have fired again at 15:29 but the post-decrement detector only triggers on the first negative crossing.

---

## Root Cause Analysis

### Running code: `inventory-nearmiss.js`

The pod is NOT running the canonical `inventory.js`. The `nearmiss-loader.js` module intercepts Node.js `require()` calls via `Module._resolveFilename` (lines 16–23 of `nearmiss-loader.js`) and substitutes `inventory-nearmiss.js` for `inventory.js` transparently — all other application code runs unmodified.

### TOCTOU race — same as prior finding, amplified

`reserveInventory()` in `inventory-nearmiss.js` (lines 38–119) has the same TOCTOU structure identified in the prior finding:

1. **Read** stock: `await getStock(item.id)` — yields control (line 48)
2. **Validate** pre-check: `if (currentStock < item.quantity)` — passes if stock ≥ quantity (line 51)
3. **Sleep** 50–150ms: `await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100))` — yields control again (line 62)
4. **Decrement**: `inventory[item.id] -= item.quantity` (line 64)
5. **Post-check**: if `newStock < 0`, emit `StockMismatchError` and throw (lines 67–94)

### Cache amplifier (new vs. prior finding)

`inventory-nearmiss.js` adds a read-through cache (`stockCache`, lines 22–35) with a **5-second TTL**. During the first 5 seconds after startup:

- All concurrent `getStock(7)` calls return the same cached value (`5`) with only 1ms simulated latency (line 28)
- This means the pre-check at line 51 passes for **all** concurrent coroutines before any decrement has occurred
- The race window is widened from the original ~5ms DB delay to **5000ms** (the full cache TTL)
- Under 3 load-generator pods requesting qty=2, all in-flight requests within the same 5-second cache window will pass the pre-check and decrement — far more concurrent decrements than the original code

### `StockMismatchError` fingerprint mechanism

The fingerprinted exception is NOT thrown by the pre-check. It is thrown only when:
- The pre-check passed (stock appeared sufficient at read time)
- The decrement was applied
- The resulting stock is negative (post-decrement check at line 67)

This means the `StockMismatchError` event marks the **exact moment the race was won by the first crossing** — subsequent errors for the same product use the "Insufficient stock" path (pre-check catches it with the now-negative live value).

### Why product 7 is uniquely affected

Product 7 (Ceramic Plant Pot) is initialized at 5 units (line 17); all others at 50. The race requires that concurrent coroutines exhaust a product's stock. With 3 load-generator pods requesting qty=2, product 7 depletes in 3 concurrent requests (3×2=6 > 5). Products initialized at 50 would require 25 concurrent successful races, which does not happen within the load profile — they deplete legitimately over time.

---

## Confidence Level

**HIGH (95%)** — Evidence is direct and multi-signal:
- Source code confirms the race mechanism and cache amplifier at exact line numbers
- ClickHouse logs show the `StockMismatchError` event at 15:15 with message matching the post-decrement detector (lines 67–72)
- ClickHouse logs show error rate jump from 4 (StockMismatchError) to 64/min (Insufficient stock) at 15:16, consistent with stock transitioning from positive to -3
- Pod describe confirms `INVENTORY_VARIANT=nearmiss` and entrypoint `nearmiss-loader.js`
- `kubectl exec` confirms `/proc/1/cmdline` matches the pod spec

---

## Comparison to Prior Finding

| Dimension | Prior Finding (2026-06-04) | Current Observation |
|---|---|---|
| Code path | `inventory.js` (canonical) | `inventory-nearmiss.js` (via module intercept) |
| Race mechanism | TOCTOU read-check-sleep-decrement | Same, **plus 5s cache amplifier** |
| Products affected | Product 7 only | Product 7 first (race), others later (depletion) |
| Error fingerprint | `StockMismatchError` via post-decrement | Same |
| Error volume | ~few per minute | 4 StockMismatch + 64–98/min downstream |
| Fix pattern | Per-product mutex in `inventory.js` | Same fix applies to `inventory-nearmiss.js`; cache must also be invalidated after decrement |

**Contradiction:** The prior finding describes the race in `inventory.js`. The current running code is `inventory-nearmiss.js`. The prior fix (mutex) was either not deployed to this pod, or this pod was deliberately re-deployed with the near-miss variant active (`INVENTORY_VARIANT=nearmiss`, entrypoint `nearmiss-loader.js`). This is a **regression or deliberate scenario re-activation**, not a recurrence of an unfixed bug in the canonical code.

**Additional gap in prior finding:** The cache amplifier in `inventory-nearmiss.js` was not described. The 5-second TTL is the primary reason the race fires so aggressively compared to the original code's ~5ms DB delay.

---

## Remediation (read-only investigation — no changes applied)

1. **Immediate:** Determine whether this pod should be running the near-miss variant. `INVENTORY_VARIANT=nearmiss` and `nearmiss-loader.js` appear to be a deliberate scenario injection (Post 11 benchmark). If not intended, redeploy with `src/server.js` as the entrypoint.

2. **If near-miss variant is intentional:** Apply the mutex fix from the prior finding to `inventory-nearmiss.js` — wrap the read-check-sleep-decrement block with `acquireLock(item.id)` / `releaseLock(item.id)`. Additionally, invalidate `stockCache[item.id]` immediately after the decrement at line 64 to prevent the cache from serving stale values to subsequent requests.

3. **Root fix for canonical code:** Verify the mutex fix from 2026-06-04 is present in `inventory.js` and that production deployments use `src/server.js`, not `nearmiss-loader.js`.
