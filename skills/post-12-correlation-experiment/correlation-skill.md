# Signal Correlation Investigation

You are investigating an incident on a Kubernetes cluster with OTel observability data.
You must complete three phases before stating a root cause. No phase may be skipped.
No root cause may be stated until Phase 3's reconciliation box holds cross-signal evidence.

## Available tools

- **kubectl** — Kubernetes CLI. KUBECONFIG is set in your environment.
- **ClickHouse** — OTel data store. Query via kubectl exec into the ClickHouse pod:
  ```sh
  kubectl exec -n clickhouse $(kubectl get pod -n clickhouse -l app=clickhouse \
    -o jsonpath='{.items[0].metadata.name}') -- clickhouse-client --query "SQL"
  ```
- **Source code** — may be available on disk or inside container images.
- **Deploy events** — may be recorded in a ClickHouse table (`deploy_events`).

---

## Phase 1: FIRING PATTERN — from telemetry alone

Establish the temporal and quantitative signature of the failure using only
telemetry (logs, traces, metrics, deploy events). Do not read source code yet.

Answer these questions with evidence:
1. **When** did the failure start? Is there a step, ramp, or spike?
2. **What** is the error shape — which services, which span names, what status codes?
3. **Did anything deploy or change** at or near the failure start time?

Record the firing pattern before proceeding. Example:
> "Error rate on gateway POST spans stepped from 0% to ~8% at 19:09 UTC.
> A deploy event for gateway v2 was recorded at 19:09:05."

---

## Phase 2: CANDIDATE MECHANISM — from code and deploy artifacts

Now read source code, inspect deployment manifests, and examine deploy diffs.

Answer these questions:
1. **What changed** in the deploy identified in Phase 1? Read the actual diff or
   compare env vars / config between the old and new deployment.
2. **What code path** could produce the error pattern observed in Phase 1?
3. Form a candidate mechanism: a specific, testable claim about how the change
   causes the failure pattern.

Record the candidate before proceeding. Example:
> "Gateway v2 lowered PROCESSOR_TIMEOUT_MS from X to Y and added retries.
> The gateway code shows it calls the processor with a deadline of Y ms.
> If the processor's tail latency exceeds Y ms, the gateway would time out and retry."

---

## Phase 3: RECONCILIATION — cross-signal evidence required

**You may not state a root cause until you fill this box with specific cross-signal
evidence that connects Phase 1 and Phase 2.**

The reconciliation must:
- Name a specific value from telemetry (Phase 1) and a specific value from
  code/deploy (Phase 2) that together explain the failure.
- The connection must be evidenced, not asserted. "The timeout is probably too low"
  is not sufficient. "The timeout is 800ms (from deploy diff) but the processor's
  observed p99 is 1060ms (from traces query X)" is sufficient.

Fill this template:
> **Telemetry value:** [specific metric/trace value from Phase 1]
> **Code/deploy value:** [specific parameter/config from Phase 2]
> **Connection:** [how these two values interact to produce the failure]

Only after filling the reconciliation box, state the root cause with full evidence
from both phases.

---

## Rules

- Complete phases in order. Do not skip ahead.
- Do not state a root cause from a single signal type. A root cause requires
  the reconciliation in Phase 3.
- If you cannot fill the reconciliation box, say so explicitly rather than
  asserting a connection you cannot evidence.
