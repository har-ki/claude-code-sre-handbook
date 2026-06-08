# Investigation Findings: ecommerce-api | StockMismatchError
**Fingerprint:** `ecommerce-api|StockMismatchError` (hash `e2836e74`)
**Date:** 2026-06-05
**Investigator:** SRE Agent (claude-sonnet-4-6)

---

## Memory Status and Validation Classification

**Prior finding loaded:** hash `e2836e74`, similarity score 0.80, resolved 2026-06-04.

> **Validation: VALIDATED** — prior finding matches current evidence. The TOCTOU race in `reserveInventory()` is confirmed active: ClickHouse shows concurrent coroutines all reading `currentStock = 5` and all proceeding to decrement, driving product 7 stock to -19. The specific error message pattern ("stock for product 7 is -19 after decrement (was 5 at read time)") exactly matches the race mechanism described in the prior finding.

**Extension to prior finding:** The currently running variant (`inventory-nearmiss.js`) introduces a **read-through cache** (`stockCache`, 5-second TTL) absent from the canonical `inventory.js`. This cache amplifies the TOCTOU window from 50–150 ms to up to 5,000 ms, allowing far more concurrent requests to read stale stock (`5`) and pass the pre-decrement check. The prior finding did not describe this amplification layer — it is new evidence from the nearmiss variant.

---

## Pod Runtime Configuration

- **Entry point:** `node -r ./src/instrumentation.js src/nearmiss-loader.js`
- **Env:** `INVENTORY_VARIANT=nearmiss`
- **What nearmiss-loader does:** Patches `Module._resolveFilename` at startup to redirect any `require()` of `services/inventory.js` to `services/inventory-nearmiss.js`. The rest of the application (checkout, products, server) runs unmodified — only the inventory implementation is swapped.
- **Pod age:** 4m8s, 0 restarts, Ready: True

---

## Error Timeline (ClickHouse: otel_logs, last 15 minutes)

| Minute (UTC-7)   | Count | Exception Type     | Message |
|------------------|-------|--------------------|---------|
| 15:28            | 7×    | `StockMismatchError` | `Inventory inconsistency: stock for product 7 (Ceramic Plant Pot) is -19 after decrement (was 5 at read time)` |
| 15:28            | 6×    | `StockMismatchError` | Same pattern, varying final stock: -17, -15, -13, -11, -9, -5 |
| 15:28            | 48    | `Error`            | `Insufficient stock for product 7: requested 2, available -3` |
| 15:28–15:32      | 84+   | `Error`            | `Insufficient stock for product 7: requested 2, available -19` |
| 15:28            | 14    | `Error`            | Stockout cascades on products 1, 4, 5, 6, 9, 11, 12 (50-unit products, transient) |

**Key observation:** All `StockMismatchError` instances report `was 5 at read time` — the cache was serving the initial stock value of 5 to all concurrent readers throughout the race window. Once stock hit -19, `getStock()` continued returning cached `-19` → errors shifted to `Insufficient stock` (negative availability).

---

## Root Cause Analysis

### Primary: TOCTOU race in `reserveInventory()` (lines 39–93 of `inventory-nearmiss.js`)

The function is async and processes items sequentially, but Node.js yields control at every `await`. The race window is:

```
Line 48:  const currentStock = await getStock(item.id);  // reads from cache or DB
           ← yields here; other coroutines may be at the same point →
Line 62:  await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));
           ← 50–150 ms yield; all coroutines that read stock=5 are now running →
Line 64:  inventory[item.id] -= item.quantity;            // all N coroutines decrement
```

Under load from the load-generator pod, N concurrent requests all reach line 48 and read `currentStock = 5` (from cache). All pass the `currentStock < item.quantity` check (5 ≥ 2). All then sleep 50–150 ms (line 62). All then decrement at line 64, producing:
```
5 - 2 - 2 - 2 - ... (×N) = 5 - 2N
```
With N=12 decrements observed: `5 - 24 = -19`. ✓

### Amplifier: Stale read-through cache in `inventory-nearmiss.js` (lines 22–34)

```js
// inventory-nearmiss.js lines 22–34
const stockCache = {};
const CACHE_TTL_MS = 5000;

async function getStock(productId) {
  const cached = stockCache[productId];
  if (cached && (Date.now() - cached.ts) < CACHE_TTL_MS) {
    await new Promise(resolve => setTimeout(resolve, 1));  // 1 ms cache hit
    return cached.value;  // returns stale value for up to 5 seconds
  }
  await new Promise(resolve => setTimeout(resolve, 5));    // 5 ms DB read
  const stock = inventory[productId];
  stockCache[productId] = { value: stock, ts: Date.now() };
  return stock;
}
```

**Absent in canonical `inventory.js`:** The canonical version reads `inventory[productId]` directly with only a 5 ms simulated delay — no cache. The nearmiss variant caches the stock value for 5,000 ms. Once the cache is populated with `5`, every subsequent `getStock(7)` call within 5 seconds returns `5` regardless of actual inventory. This:

1. Extends the TOCTOU window from ~5 ms (canonical) to up to 5,000 ms (nearmiss)
2. Allows dozens of concurrent requests to pass the pre-decrement check during a single cache TTL window
3. Explains why stock reached -19 (12 concurrent decrements) vs. the 2–3 concurrent decrements possible in the shorter canonical window

### Why product 7 specifically

Product 7 (Ceramic Plant Pot) is initialized with `5` units; all others have `50`. Under load requesting quantity 2, only product 7 can be exhausted in a single cache TTL cycle (5 units / 2 per request = 2.5 valid requests before depletion). The 5-second cache window allows all concurrent requests in a burst to read `5` before any decrement updates the cache.

---

## Confidence Level

**High (0.92).** The evidence is unambiguous:
- ClickHouse `StockMismatchError` logs quote `was 5 at read time` — proving cache staleness, not just a race
- Negative stock of -19 is arithmetically consistent with 12 concurrent decrements of 2 from initial stock of 5
- Source code confirms the cache at `inventory-nearmiss.js:26-29` and the identical TOCTOU structure at lines 48, 62, 64
- Pod describe confirms `nearmiss-loader.js` entry point and `INVENTORY_VARIANT=nearmiss`
- No alternative explanation for why all readers would see `5` simultaneously after stock was depleted

---

## Does the Prior Finding Match or Contradict Current Observations?

**Matches on:**
- Root mechanism: TOCTOU in `reserveInventory()` (read → validate → sleep → decrement, no atomic lock)
- Affected product: Product 7, Ceramic Plant Pot, 5 initial units
- Error message format: `Inventory inconsistency: stock for product 7 ... is <N> after decrement (was 5 at read time)`
- Fix pattern: per-product mutex to make read-check-decrement atomic

**Extends beyond prior finding:**
- The currently running code is `inventory-nearmiss.js`, not the canonical `inventory.js` the prior finding analyzed
- The nearmiss variant adds a 5-second read-through cache (`stockCache`, `CACHE_TTL_MS = 5000`) that the prior finding did not mention
- This cache is the "near-miss" teaching element: it looks like a performance optimization but catastrophically amplifies the race window from ~5 ms to 5,000 ms, making the bug far more reproducible and severe under any realistic load

**No contradictions found.**
