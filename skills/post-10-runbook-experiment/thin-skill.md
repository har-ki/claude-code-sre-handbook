# Investigation Hints

You are investigating an incident on a Kubernetes cluster with OTel observability data.

## Available tools

- **kubectl** — Kubernetes CLI. KUBECONFIG is set in your environment.
- **ClickHouse** — OTel data store. CLI binary is `clickhouse client` (two words, not hyphenated).
  Access via kubectl exec into the ClickHouse pod:
  ```sh
  kubectl exec -n clickhouse $(kubectl get pod -n clickhouse -l app=clickhouse \
    -o jsonpath='{.items[0].metadata.name}') -- clickhouse client --query "SQL"
  ```

## Where to look

- **Recent logs:** Query `otel_logs` table. Filter by `ServiceName` and `SeverityText`.
  Exception details are in `LogAttributes['exception.type']`, `LogAttributes['exception.message']`, `LogAttributes['exception.stacktrace']`.
- **Recent traces:** Query `otel_traces` table. `Duration` is in nanoseconds (divide by 1e6 for ms). `StatusCode` values are `'Ok'`, `'Error'`, `'Unset'` (not prefixed).
- **Recent deploys:** Check deployment history with `kubectl rollout history`.
- **Failing source:** Read the application source code to understand the code path.

## ClickHouse column notes

| Table | Timestamp column | Service column |
|-------|-----------------|----------------|
| `otel_logs` | `Timestamp` | `ServiceName` |
| `otel_traces` | `Timestamp` | `ServiceName` |
| `otel_metrics_gauge` / `_sum` / `_histogram` | `TimeUnix` | `ResourceAttributes['service.name']` |

- `SeverityText` varies by framework: `'ERROR'`, `'Error'`, `'error'`. Use `IN` clause for robust matching.
- Use bracket syntax for Map columns: `LogAttributes['exception.type']`. Do NOT use dot syntax or `LIKE` on Map columns.
- Shell quoting: use double quotes around `--query` when SQL contains string literals.
- Always include `LIMIT` and a time window filter.
- Read-only access only. Never execute INSERT, CREATE, ALTER, DROP.

Complete the investigation autonomously. Do not ask questions.
