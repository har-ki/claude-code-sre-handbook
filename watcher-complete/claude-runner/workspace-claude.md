# Incident workspace

This is a working clone used by the incident watcher. Follow these conventions.

## Source code layout

- `otel-demo/ecommerce/backend/src/routes/checkout.js` — checkout endpoint
- `otel-demo/ecommerce/backend/src/services/inventory.js` — inventory service
- `otel-demo/ecommerce/backend/src/services/payment.js` — payment service

## Templates

- `templates/incident-report.md` — incident report template (use this for `docs/incidents/` reports)

## ClickHouse access

ClickHouse is NOT available as a local binary. Query via kubectl API proxy:

```bash
kubectl get --raw "/api/v1/namespaces/clickhouse/services/clickhouse:8123/proxy/?query=<URL-encoded-SQL>"
```

URL encoding reference: space=`%20`, `'`=`%27`, `[`=`%5B`, `]`=`%5D`, `=`=`%3D`, `>`=`%3E`, `<`=`%3C`, `(`=`%28`, `)`=`%29`, `,`=`%2C`, `/`=`%2F`

Tables: `otel_logs`, `otel_traces`, `otel_metrics_gauge`, `otel_metrics_sum`

## Memory store

A per-incident memory store is mounted at `/memory-store/incidents/`. Each file is named `<fingerprint-hash>.md` and contains the root cause + fix pattern from a prior resolution.

- **Phase 1:** Read `/memory-store/incidents/<hash>.md` at the start of investigation. If it exists, use it as prior context. When validation discipline is active, you MUST classify the finding as validated/invalidated/inconclusive before proceeding. If outcome data is present (outcome, verdict, lesson), include it in your investigation — it represents grounded feedback from a real merge.
- **Phase 2:** Write `/memory-store/incidents/<hash>.md` after completing the fix. This is required — do not skip it.

The agent reads memory-store/ ONLY. It does NOT read incident-store/ reports.

Use the `Read` tool to read memory files and the `Write` tool to write them. The hash is in the `$FP_HASH` env var.

## Other tools

- `kubectl` — cluster access (read-only in Phase 1)
- `gh` — GitHub CLI for PR operations (authenticated via GH_TOKEN)

Do NOT use the Skill tool or ToolSearch — all tools are already available as Bash commands.

## Phase 2 conventions

- The incident branch is already checked out and up to date. Just edit, commit, and push.
- Branch name is in `$INCIDENT_BRANCH` env var. Use `git pull --rebase origin $INCIDENT_BRANCH` before your first commit.
- Incident reports go in `docs/incidents/<date>-<fp_hash>.md`.
- Push to the current branch. Do NOT run `gh pr ready`.
