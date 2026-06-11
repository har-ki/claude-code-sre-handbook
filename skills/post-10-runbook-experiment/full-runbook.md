# Incident Investigation Runbook

You are investigating an incident on a Kubernetes cluster with OTel observability data.
Follow the three-phase workflow below. Do not skip phases. Execute autonomously — do not
stop to ask questions.

## Available tools

- **kubectl** — Kubernetes CLI. KUBECONFIG is set in your environment.
- **ClickHouse** — OTel data store. CLI binary is `clickhouse client` (two words, not hyphenated).
  Access via kubectl exec into the ClickHouse pod:
  ```sh
  kubectl exec -n clickhouse $(kubectl get pod -n clickhouse -l app=clickhouse \
    -o jsonpath='{.items[0].metadata.name}') -- clickhouse client --query "SQL"
  ```

---

## Phase 1: INVESTIGATE — Establish scope and identify candidate root cause

Work through these steps in order. Stop as soon as you have a candidate root cause
to carry into Phase 2.

**Step 1 — Scope:** Establish the time window and affected services.
```sh
clickhouse client --query 'SELECT max(Timestamp) FROM otel_logs'
clickhouse client --query 'SELECT DISTINCT ServiceName FROM otel_logs ORDER BY ServiceName'
```

**Step 2 — Triage:** Error rates across services in the last hour.
```sh
clickhouse client --query "
SELECT ServiceName,
  countIf(SeverityText IN ('ERROR','Error','error')) AS errors, count() AS total
FROM otel_logs WHERE Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY ServiceName ORDER BY errors DESC LIMIT 15
"
```

**Step 3 — Drill:** Focus on the problem service. Get error messages and stack traces.
```sh
clickhouse client --query "
SELECT Body, count() AS cnt FROM otel_logs
WHERE ServiceName = '<service>'
  AND SeverityText IN ('ERROR','Error','error')
  AND Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY Body ORDER BY cnt DESC LIMIT 10
"

clickhouse client --query "
SELECT
    LogAttributes['exception.type'] AS exc_type,
    LogAttributes['exception.message'] AS exc_message,
    LogAttributes['exception.stacktrace'] AS stacktrace
FROM otel_logs
WHERE ServiceName = '<service>'
  AND LogAttributes['exception.type'] != ''
  AND Timestamp >= now() - INTERVAL 1 HOUR
LIMIT 3
"
```

**Step 4 — Trace latency** (if relevant): Check for slow operations.
```sh
clickhouse client --query "
SELECT SpanName, quantile(0.95)(Duration/1e6) AS p95_ms, count() AS cnt
FROM otel_traces
WHERE ServiceName = '<service>' AND Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY SpanName ORDER BY p95_ms DESC LIMIT 10
"
```

When you have a candidate root cause (e.g. an exception type, a code path, a
latency spike), proceed to Phase 2. Do not continue querying speculatively.

**Query budget:** Maximum 10 ClickHouse queries across the entire investigation.
Never re-run a query you already executed.

---

## Phase 2: CORROBORATE — Verify the candidate before concluding

**You must cross-reference at least two independent signal types before stating a
root cause.** A single signal (logs alone, traces alone, code alone) is not sufficient.

Choose the corroboration path that fits your candidate:

- **Found it in logs → verify in traces or code:**
  Check whether error traces correlate with the log timestamps. Read the source
  code to confirm the mechanism that produces the error.

- **Found it in traces → verify in logs or code:**
  Check whether error logs appear around the same time. Read the source code to
  understand why the operation is slow or failing.

- **Found it in code → verify in logs or traces:**
  Confirm the code-level bug is actually being triggered by checking logs for the
  expected error pattern or traces for the expected latency/status pattern.

**Cross-signal correlation query pattern:**
```sh
clickhouse client --query "
SELECT l.Timestamp, l.ServiceName, l.SeverityText, l.Body
FROM otel_logs l
WHERE l.TraceId IN (
    SELECT TraceId FROM otel_traces
    WHERE ServiceName = '<service>' AND StatusCode = 'Error'
    ORDER BY Timestamp DESC LIMIT 5
)
ORDER BY l.Timestamp LIMIT 20
"
```

**Read the source code.** Use `cat` or file-reading tools to inspect the code path
identified by the stack trace. Understand the mechanism — do not just name the error.

**Look for multiple contributing factors.** If the bug has more than one driver
(e.g. a race condition AND a missing guard), identify all of them. Do not stop at
the first explanation if the code or data suggests additional issues.

**Verification rule:** Do not proceed to Phase 3 until you can cite evidence from
at least two signal types (logs + traces, logs + code, traces + code, or all three).

---

## Phase 3: CONCLUDE — State root cause with evidence

State the root cause clearly and completely:

1. **Root cause:** One-paragraph summary of what is happening and why.
2. **Evidence:** For each signal type consulted, cite the specific query and what it showed.
3. **All contributing factors:** List every issue identified, not just the primary one.
   If there are multiple drivers (e.g. a timing issue + a missing atomicity guard),
   enumerate each separately.
4. **Suggested remediation:** What code or configuration change would fix each issue.

---

## ClickHouse column reference

| Table | Timestamp column | Service column |
|-------|-----------------|----------------|
| `otel_logs` | `Timestamp` | `ServiceName` |
| `otel_traces` | `Timestamp` | `ServiceName` |
| `otel_metrics_gauge` / `_sum` / `_histogram` | `TimeUnix` | `ResourceAttributes['service.name']` |

- `SeverityText` varies: `'ERROR'`, `'Error'`, `'error'`. Use `IN` clause.
- Exception details: `LogAttributes['exception.type']`, `['exception.message']`, `['exception.stacktrace']`.
- Use bracket syntax for Map columns. Do NOT use dot syntax or `LIKE` on Map columns.
- `Duration` (otel_traces) is in nanoseconds — divide by 1e6 for milliseconds.
- `StatusCode` values: `'Ok'`, `'Error'`, `'Unset'` (not prefixed).
- Shell quoting: double-quote `--query` when SQL contains string literals.
- Always include `LIMIT` and a time window filter.
- Read-only access only. Never execute INSERT, CREATE, ALTER, DROP.
