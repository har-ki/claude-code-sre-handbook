---
name: clickhouse
description: >
  Query OTel observability data (logs, traces, metrics) via ClickHouse to
  investigate incidents. Use when the user mentions clickhouse, otel logs,
  otel traces, observability data, investigate traces, query metrics, or
  clickstack.
---

# ClickHouse Integration

PURPOSE: Investigate incidents by querying OpenTelemetry observability data (logs, traces, metrics) stored in ClickHouse.

## Critical Rules

**Tables — query ONLY these OTel tables:**
- `otel_logs` — application logs (has `Timestamp`, `ServiceName`)
- `otel_traces` — distributed traces / spans (has `Timestamp`, `ServiceName`, `Duration`)
- `otel_metrics_gauge` — gauge metrics (has `TimeUnix`, NO `ServiceName` — use `ResourceAttributes['service.name']`)
- `otel_metrics_sum` — counter/sum metrics (same as gauge)
- `otel_metrics_histogram` — histogram metrics (same as gauge)

Do NOT query `system.*` tables or `otel_traces_trace_id_ts` (lookup-only table).

**Column name differences across tables:**
- Timestamp: `otel_logs` and `otel_traces` use `Timestamp`. Metrics tables use `TimeUnix`.
- ServiceName: `otel_logs` and `otel_traces` have `ServiceName`. Metrics tables do NOT — use `ResourceAttributes['service.name']`.
- Duration: Only in `otel_traces`. Value is in nanoseconds — divide by `1e6` for milliseconds.

**SeverityText values vary by language/framework:**
`'ERROR'`, `'Error'`, `'error'`, `'WARN'`, `'Warning'`, `'INFO'`, `'Information'`.
For robust matching use: `SeverityText IN ('ERROR', 'Error', 'error')`.

**Exception details are in LogAttributes, NOT in Body:**
Use `LogAttributes['exception.type']`, `LogAttributes['exception.message']`, `LogAttributes['exception.stacktrace']`.
Do NOT use `LIKE` on Map columns — use bracket syntax.

**Shell quoting — use this pattern for queries with string literals:**
```sh
clickhouse client --query "
SELECT ServiceName, countIf(SeverityText IN ('ERROR','Error','error')) AS errors
FROM otel_logs WHERE Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY ServiceName ORDER BY errors DESC LIMIT 10
"
```
NEVER use single quotes around `--query` when SQL contains string literals — this breaks shell quoting.

**CLI binary — always use `clickhouse client` (two words):**
- CORRECT: `clickhouse client --query "SELECT 1"`
- WRONG: `clickhouse-client` (deprecated hyphenated form)
- WRONG: `clickhouse query` (does not exist)
- WRONG: `clickhouse --query` (missing `client` subcommand)

**Read-only access only.** Never execute INSERT, CREATE, ALTER, DROP, TRUNCATE, or any write operation.

**Always include LIMIT and time window filters.** Never run `SELECT *` without LIMIT.

Connection options: `--host`, `--port`, `--user`, `--password`, `--database`, `--format`.

## Investigation Methodology

WORKFLOW: SCOPE → TRIAGE → DRILL → MEASURE → CORRELATE → CONCLUDE

Execute queries autonomously — do not stop to ask the user for permission between steps.

**Step 1: SCOPE** — Establish time window and affected services
```sh
clickhouse client --query 'SELECT max(Timestamp) FROM otel_logs'
clickhouse client --query 'SELECT DISTINCT ServiceName FROM otel_logs ORDER BY ServiceName'
```

**Step 2: TRIAGE** — Error rates and latency across all services
```sh
# Error rates
clickhouse client --query "
SELECT ServiceName,
  countIf(SeverityText IN ('ERROR','Error','error')) AS errors, count() AS total
FROM otel_logs WHERE Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY ServiceName ORDER BY errors DESC LIMIT 15
"

# Latency percentiles
clickhouse client --query "
SELECT ServiceName, SpanName,
  quantile(0.95)(Duration / 1e6) AS p95_ms, count() AS spans
FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY ServiceName, SpanName ORDER BY p95_ms DESC LIMIT 15
"
```

**Step 3: DRILL** — Focus on the problem service
```sh
# Error messages
clickhouse client --query "
SELECT Body, count() AS cnt FROM otel_logs
WHERE ServiceName = '<service>'
  AND SeverityText IN ('ERROR','Error','error')
  AND Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY Body ORDER BY cnt DESC LIMIT 10
"

# Exception stack traces
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

**Step 4: MEASURE** — Quantify latency per operation
```sh
clickhouse client --query "
SELECT SpanName, quantile(0.95)(Duration/1e6) AS p95_ms, count() AS cnt
FROM otel_traces
WHERE ServiceName = '<service>' AND Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY SpanName ORDER BY p95_ms DESC LIMIT 10
"
```

**Step 5: CORRELATE** — Cross-reference logs + traces + metrics
```sh
# Logs for slow traces
clickhouse client --query "
SELECT l.Timestamp, l.ServiceName, l.SeverityText, l.Body
FROM otel_logs l
WHERE l.TraceId IN (
    SELECT TraceId FROM otel_traces
    WHERE ServiceName = '<service>' AND Duration > 5000000000
    ORDER BY Timestamp DESC LIMIT 5
)
ORDER BY l.Timestamp LIMIT 20
"

# Memory metrics for the service
clickhouse client --query "
SELECT ResourceAttributes['service.name'] AS svc, TimeUnix, Value
FROM otel_metrics_gauge
WHERE ResourceAttributes['service.name'] = '<service>'
  AND TimeUnix >= now() - INTERVAL 1 HOUR
ORDER BY TimeUnix LIMIT 20
"
```

**Step 6: CONCLUDE** — State root cause with evidence
- State the root cause clearly
- Reference specific queries and data points as evidence
- Suggest remediation steps

## Schema Reference

### otel_logs

| Column | Type | Description |
|--------|------|-------------|
| Timestamp | DateTime64(9) | Log timestamp (nanosecond precision) |
| TraceId | String | W3C trace ID for correlation |
| SpanId | String | Span ID for correlation |
| SeverityText | LowCardinality(String) | Log level (varies: ERROR, Error, error, etc.) |
| ServiceName | LowCardinality(String) | Originating service name |
| Body | String | Log message body |
| ResourceAttributes | Map(LowCardinality(String), String) | Resource-level attributes |
| LogAttributes | Map(LowCardinality(String), String) | Log-level attributes (exception.type, exception.message, exception.stacktrace) |

### otel_traces

| Column | Type | Description |
|--------|------|-------------|
| Timestamp | DateTime64(9) | Span start time |
| TraceId | String | W3C trace ID |
| SpanId | String | Unique span identifier |
| ParentSpanId | String | Parent span (empty for root spans) |
| SpanName | LowCardinality(String) | Operation name |
| SpanKind | LowCardinality(String) | SPAN_KIND_SERVER, SPAN_KIND_CLIENT, etc. |
| ServiceName | LowCardinality(String) | Originating service |
| SpanAttributes | Map(LowCardinality(String), String) | Span-level attributes |
| Duration | UInt64 | Span duration in nanoseconds (divide by 1e6 for ms) |
| StatusCode | LowCardinality(String) | `Ok`, `Error`, `Unset` (NOT prefixed — do not use `STATUS_CODE_*`) |
| StatusMessage | String | Error message (when StatusCode=ERROR) |

### otel_metrics_gauge / otel_metrics_sum

| Column | Type | Description |
|--------|------|-------------|
| ResourceAttributes | Map(LowCardinality(String), String) | Use `ResourceAttributes['service.name']` for service name |
| MetricName | LowCardinality(String) | Metric name |
| MetricUnit | String | Unit (e.g., 'By', 'ms') |
| Attributes | Map(LowCardinality(String), String) | Metric attributes |
| TimeUnix | DateTime64(9) | Observation time (NOT Timestamp) |
| Value | Float64 | Metric value |

`otel_metrics_sum` also has: `AggTemp` (Int32), `IsMonotonic` (Boolean).

### otel_metrics_histogram

| Column | Type | Description |
|--------|------|-------------|
| ResourceAttributes | Map(LowCardinality(String), String) | Use `ResourceAttributes['service.name']` for service name |
| MetricName | LowCardinality(String) | Metric name |
| TimeUnix | DateTime64(9) | Observation time (NOT Timestamp) |
| Count | UInt64 | Number of observations |
| Sum | Float64 | Sum of observations |
| BucketCounts | Array(UInt64) | Histogram bucket counts |
| ExplicitBounds | Array(Float64) | Histogram bucket boundaries |
| Min | Float64 | Minimum value |
| Max | Float64 | Maximum value |

## SQL Patterns Reference

### Map field access
```sql
SELECT ResourceAttributes['service.name'] AS service FROM otel_logs LIMIT 10;
SELECT ServiceName, SpanName, Duration / 1e6 AS ms FROM otel_traces WHERE SpanAttributes['http.status_code'] = '500' LIMIT 20;
```

### Cross-signal correlation
```sql
-- Logs for a specific trace
SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE TraceId = '<trace_id>' ORDER BY Timestamp;

-- Logs for error traces
SELECT l.Timestamp, l.ServiceName, l.SeverityText, l.Body
FROM otel_logs l
INNER JOIN (
    SELECT DISTINCT TraceId FROM otel_traces
    WHERE StatusCode = 'STATUS_CODE_ERROR' AND Timestamp >= now() - INTERVAL 30 MINUTE LIMIT 10
) t ON l.TraceId = t.TraceId
ORDER BY l.Timestamp;
```

### Discovery queries
```sql
SELECT DISTINCT ServiceName FROM otel_logs ORDER BY ServiceName;
SELECT DISTINCT ServiceName FROM otel_traces ORDER BY ServiceName;
SELECT DISTINCT MetricName FROM otel_metrics_gauge ORDER BY MetricName;
SELECT DISTINCT arrayJoin(mapKeys(LogAttributes)) AS key FROM otel_logs LIMIT 100;
SELECT max(Timestamp) AS latest_log FROM otel_logs;
```

## Efficiency Rules

- **Never re-query data you already have.** If a query returned results, use those results — do not run the same or similar query again.
- **If a table or service returned empty once, do not query it again.**
- **Deliver your summary as soon as you have evidence for a root cause.** Do not keep querying for confirmation. State what you found, cite the data, and conclude.
- **Limit total queries to 15.** If you haven't found the root cause in 15 queries, summarize what you know so far and ask the user for guidance.

## NEVER

| Don't Do This | What Happens |
|---------------|--------------|
| `SELECT *` without LIMIT | Massive output, context blown |
| Missing LIMIT on queries | Unbounded result set, OOM |
| `INSERT`, `ALTER`, `DROP` | Corrupts data or schema |
| `ResourceAttributes.service.name` (dot syntax) | Wrong — use `ResourceAttributes['service.name']` |
| Forgetting nanosecond Duration | Divide by 1e6 for ms |
| Single-quoted `--query` with string literals inside | Shell quote collision |
| `WHERE Timestamp >= ...` on metrics tables | Metrics use `TimeUnix`, not `Timestamp` |
| `WHERE ServiceName = '...'` on metrics tables | Metrics have no `ServiceName` |
| `LIKE` on Map columns | Use bracket syntax: `LogAttributes['exception.type']` |
| Querying `system.*` tables | Those are ClickHouse internals, not OTel data |

## Checklist (verify before completing investigation)

- [ ] Queried at least 2 signal types (logs + traces, or traces + metrics)
- [ ] All queries include LIMIT and time window filter
- [ ] Root cause stated with supporting evidence from query results
- [ ] No write operations executed
