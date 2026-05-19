# OTel + ClickHouse Demo Environment

Local Kubernetes environment for the handbook's investigation scenarios. Runs a
kind cluster with an ecommerce API, OpenTelemetry instrumentation, and
ClickHouse for log/trace/metric storage.

## Architecture

```text
ecommerce namespace                    default namespace
┌──────────────┐   OTLP gRPC :4317    ┌──────────────────────┐
│ ecommerce-api├──────────────────────►│ otel-clickhouse-     │
│ (Node.js)    │                       │ bridge               │
└──────────────┘                       │ (collector-contrib)  │
┌──────────────┐                       └──────────┬───────────┘
│ load-        │                                  │ native :9000
│ generator    │                       ┌──────────▼───────────┐
└──────────────┘                       │ clickhouse           │
                                       │ NodePort 30900→9000  │
                                       └──────────────────────┘
```

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Quick start

```bash
./setup.sh        # ~3 minutes on first run
```

The script is idempotent. It creates a kind cluster named `claude-sre-demo`
(override with `KIND_CLUSTER=name`), builds the ecommerce-api image from local
source under `ecommerce/backend/`, deploys infrastructure, and waits until OTel
data is flowing into ClickHouse.

## Querying ClickHouse

From the host (via kind NodePort):

```bash
clickhouse client --port 9000
```

From inside the cluster:

```bash
kubectl exec -it -n clickhouse deploy/clickhouse -- clickhouse-client
```

### Key tables

| Table | Time column | Service column |
|---|---|---|
| `otel_logs` | `Timestamp` | `ServiceName` |
| `otel_traces` | `Timestamp` | `ServiceName` |
| `otel_metrics_gauge` | `TimeUnix` | `ResourceAttributes['service.name']` |
| `otel_metrics_sum` | `TimeUnix` | `ResourceAttributes['service.name']` |
| `otel_metrics_histogram` | `TimeUnix` | `ResourceAttributes['service.name']` |

### Example queries

```sql
-- Recent errors
SELECT Timestamp, SeverityText, Body, LogAttributes
FROM otel_logs
WHERE SeverityText IN ('ERROR', 'Error', 'error')
ORDER BY Timestamp DESC
LIMIT 10;

-- Slow traces
SELECT ServiceName, SpanName, Duration / 1e6 AS duration_ms
FROM otel_traces
ORDER BY Duration DESC
LIMIT 10;
```

## Reproducing the Post 2 demo

The [Post 2 walkthrough](../docs/handbook/02-investigation-to-pr.md) runs Claude Code against this cluster. Prerequisites beyond the cluster: [Claude Code](https://claude.ai/claude-code), [GitHub CLI](https://cli.github.com/) (`gh`), and an Anthropic API key.

```bash
# 1. Stand up the cluster
./setup.sh

# 2. Push the ecommerce app to your own GitHub
cd ecommerce
git init && gh repo create ecommerce-app --public --source=. --push
cd ..

# 3. Install the Skills
cp -r ../skills/* ~/.claude/skills/

# 4. Authenticate the GitHub CLI (if not already)
gh auth login
```

Then open Claude Code and paste the three prompts from the post.

## Teardown

```bash
./teardown.sh
```

## Environment variable overrides

| Variable | Default | Purpose |
|---|---|---|
| `KIND_CLUSTER` | `claude-sre-demo` | Kind cluster name |
