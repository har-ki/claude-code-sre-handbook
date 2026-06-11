# Test Incidents

Three test cases for the semantic memory experiment. Each tests a different
retrieval scenario.

## 1. Drift (hash: de61efe2)

**Fingerprint:** `ecommerce-api|InventoryValidationError`

Same TOCTOU race root cause as the canonical incident, but the exception class
was renamed from `StockMismatchError` to `InventoryValidationError` (simulating
a code refactor). Exact-hash lookup MISSES because the hash differs. Similarity
search should find the canonical finding (same service, similar exception semantics).

**Expected behavior:**
- `exact` mode: no finding (different hash)
- `similarity` mode: finds canonical finding (high similarity score)

## 2. Near-miss (hash: e2836e74 — same as canonical)

**Fingerprint:** `ecommerce-api|StockMismatchError`

Same service + exception as the canonical incident but with a stale-read cache
bug layered on top. Uses the existing `inventory-nearmiss.js` variant (see
`otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js`). The hash
collides with the canonical incident.

**Expected behavior:**
- `exact` mode: finds canonical finding (hash collision)
- `similarity` mode: finds canonical finding (high score, same description)
- Both modes surface a finding that is partially wrong for this incident

## 3. No-precedent (hash: 2c8fc300)

**Fingerprint:** `ecommerce-api|PaymentGatewayTimeout`

A payment timeout incident with no relevant stored finding. Tests that the
retrieval layer stays silent when nothing matches.

**Expected behavior:**
- `exact` mode: no finding (no file at 2c8fc300.md)
- `similarity` mode: no finding (score below threshold — stock/inventory
  findings are not semantically similar to payment timeouts)

## Seeding memory for tests

Run `seed-memory.sh` to:
1. Copy the canonical finding to `memory-store/incidents/e2836e74.md`
2. Embed it and add to the vector index
