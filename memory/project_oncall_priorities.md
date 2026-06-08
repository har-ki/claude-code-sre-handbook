---
name: On-call monitoring priorities
description: Top 3 services to prioritize for on-call monitoring and the rationale behind each priority (triaged 2026-06-02)
type: project
---

## Prioritized on-call monitoring (top 3 of 6) — triaged 2026-06-02

### 1. payment-gateway — HIGHEST PRIORITY
- **Why:** Direct revenue impact. Any downtime or latency spike means money is actively being lost. Payment failures also trigger chargebacks, refund disputes, and regulatory exposure.
- **What to monitor:** Transaction success rate, latency p99, error rate (4xx/5xx), connection pool saturation, downstream provider health (Stripe, etc.)
- **Alert threshold:** Success rate < 99.5% over 1 min, p99 latency > 2s

### 2. user-auth — SECOND PRIORITY
- **Why:** Authentication is the gate to every other service. If user-auth goes down, the entire platform becomes inaccessible — no payments, no inventory lookups, no notifications. It's a single point of failure for user access.
- **What to monitor:** Auth success rate, token issuance latency, session store connectivity, brute-force attempt rate
- **Alert threshold:** Auth failure rate > 1%, token issuance latency p99 > 500ms

### 3. inventory-sync — THIRD PRIORITY
- **Why:** Inventory data inconsistency causes operational chaos — overselling, shipping delays, and customer complaints. Unlike auth or payments, this is a data-reliability issue that compounds over time and is hard to recover from retroactively.
- **What to monitor:** Sync lag (seconds behind source of truth), sync failure count, data divergence rate, queue depth
- **Alert threshold:** Sync lag > 30s, failure count > 0 for 5 min

## Lower priority (monitor but not on-call urgent)

- **notification-service** — Delivery delays are annoying but rarely cause revenue loss or platform outage. Batching and retry logic absorb short disruptions.
- **search-indexer** — Search degradation is noticeable but users can still browse and purchase. Index rebuilds are low-risk operations.
- **metrics-collector** — This is the observability tool itself. If it goes down, you lose visibility but the platform keeps running. Fix within hours, not minutes.
