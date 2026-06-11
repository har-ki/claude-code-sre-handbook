#!/usr/bin/env bash
set -euo pipefail

CAPTURE_DIR="/tmp/nearmiss-capture"
MEMORY_DIR="${CAPTURE_DIR}/memory-store/incidents"
AUDIT_DIR="${CAPTURE_DIR}/audit-log"
RESULTS_DIR="${CAPTURE_DIR}/results"
REPO_DIR="/Users/harikirannayak/Documents/workspace/claude-code-sre-handbook"

SERVICE="ecommerce-api"
FP_HASH="e2836e74"
DATE="$(date -u +%Y-%m-%d)"
MODEL="claude-sonnet-4-6"

echo "================================================================"
echo "RUN 1 — COLD GATE (near-miss variant, no memory)"
echo "$(date -u +%FT%TZ)"
echo "================================================================"
echo "Stack:       frontier ${MODEL}"
echo "Variant:     near-miss (stale-cache)"
echo "Memory:      EMPTY (cold)"
echo ""

# ── Cold Phase 1: Investigate from scratch ──────────────────────────
COLD_P1_AUDIT="${AUDIT_DIR}/nearmiss-cold-phase1-${FP_HASH}.jsonl"
COLD_P1_START="$(date -u +%FT%TZ)"

COLD_P1_PROMPT="You are an SRE agent investigating an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${SERVICE}|StockMismatchError\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** StockMismatchError
- **Date:** ${DATE}

## Prior findings (memory)

Before starting your investigation, check if this incident fingerprint has been seen before:

1. Read the file \`${MEMORY_DIR}/${FP_HASH}.md\` using the Read tool.
2. If the file exists, use it as context for your investigation.
3. If the file does not exist (Read returns an error), this is a new incident fingerprint. Proceed with a fresh investigation.

Include one of these at the top of your findings:
- \`> **Memory:** Prior finding loaded from ${MEMORY_DIR}/${FP_HASH}.md\`
- \`> **Memory:** No prior finding for fingerprint ${FP_HASH}\`

## Task

1. Query ClickHouse for recent errors from ${SERVICE}:
   \`\`\`bash
   kubectl exec -n clickhouse deploy/clickhouse -- clickhouse-client --query \"<SQL>\"
   \`\`\`
   Query otel_logs for the last 15 minutes: error counts, exception types, LogAttributes['exception.type'], LogAttributes['exception.message'], LogAttributes['product.id'], LogAttributes['product.name'].

2. Check Kubernetes pod health:
   \`\`\`bash
   kubectl get pods -n ecommerce
   kubectl describe pod -l app=ecommerce-api -n ecommerce
   \`\`\`

3. Read the application source code at \`${REPO_DIR}/otel-demo/ecommerce/backend/src/\`. Read ALL service files — especially services/inventory.js (or any variant loaded). Also check the entrypoint to understand which module is actually running.
   - Check \`kubectl exec -n ecommerce deploy/ecommerce-api -- cat /app/src/services/inventory-nearmiss.js\` or equivalent to see what the pod is actually running.
   - Read the actual inventory module the pod is using, not just the canonical one.

4. Write your investigation findings to \`${RESULTS_DIR}/nearmiss-cold-phase1-findings.md\`. Include:
   - Memory status (hit or miss)
   - Error timeline and counts from ClickHouse
   - Root cause analysis — explain the specific mechanism causing StockMismatchError
   - Confidence level (high/medium/low)
   - Specific evidence: error counts, log lines, code line references

## Rules

- You are **read-only** on the cluster and on git. Do not create commits or apply changes.
- Be specific: quote error messages, counts, and code locations.
- Focus on understanding WHY the stock goes negative — trace the exact code path.
"

echo "Running Cold Phase 1..."
echo "Audit: ${COLD_P1_AUDIT}"

claude -p "${COLD_P1_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Read,Write,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${COLD_P1_AUDIT}" 2>&1

COLD_P1_EXIT=$?
COLD_P1_END="$(date -u +%FT%TZ)"
COLD_P1_TURNS=$(grep '"type":"result"' "${COLD_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
COLD_P1_COST=$(grep '"type":"result"' "${COLD_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Cold Phase 1: exit=${COLD_P1_EXIT} turns=${COLD_P1_TURNS} cost=\$${COLD_P1_COST}"
echo "Duration: ${COLD_P1_START} → ${COLD_P1_END}"
echo ""

# ── Cold Phase 2: Fix + Memory Write ────────────────────────────────
COLD_P2_AUDIT="${AUDIT_DIR}/nearmiss-cold-phase2-${FP_HASH}.jsonl"
COLD_P2_START="$(date -u +%FT%TZ)"

COLD_P1_FINDINGS=""
if [[ -f "${RESULTS_DIR}/nearmiss-cold-phase1-findings.md" ]]; then
  COLD_P1_FINDINGS=$(cat "${RESULTS_DIR}/nearmiss-cold-phase1-findings.md")
fi

COLD_P2_PROMPT="You are an SRE agent proposing a fix for an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${SERVICE}|StockMismatchError\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** StockMismatchError
- **Date:** ${DATE}

## Phase 1 Findings

${COLD_P1_FINDINGS:-Phase 1 investigation completed. Read the findings file for details.}

## Task

1. Read the application source code the pod is actually running. The pod may use a variant of inventory.js. Check what's loaded:
   \`\`\`bash
   kubectl exec -n ecommerce deploy/ecommerce-api -- cat /app/src/services/inventory-nearmiss.js
   \`\`\`
   Also read the local copy at \`${REPO_DIR}/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js\` if the kubectl read fails.

2. Propose a minimal, targeted fix for the root cause identified in Phase 1. Write your fix proposal to \`${RESULTS_DIR}/nearmiss-cold-phase2-fix.md\`. Include the specific code change.

3. **Persist findings to memory store.** Write the root cause and fix pattern to \`${MEMORY_DIR}/${FP_HASH}.md\` using the Write tool. Use this exact format:

   \`\`\`
   # Prior Finding: ${FP_HASH}

   ## Root Cause
   <one-paragraph root cause>

   ## Fix Pattern
   <one-paragraph description of the fix>

   ## Resolved
   ${DATE} via nearmiss-cold-run capture
   \`\`\`

   This step is REQUIRED — do not skip it.

## Rules

- Do NOT run \`gh pr ready\`.
- Do NOT mutate the cluster.
- Keep the fix minimal.
"

echo "Running Cold Phase 2..."
echo "Audit: ${COLD_P2_AUDIT}"

claude -p "${COLD_P2_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Read,Write,Edit,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${COLD_P2_AUDIT}" 2>&1

COLD_P2_EXIT=$?
COLD_P2_END="$(date -u +%FT%TZ)"
COLD_P2_TURNS=$(grep '"type":"result"' "${COLD_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
COLD_P2_COST=$(grep '"type":"result"' "${COLD_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Cold Phase 2: exit=${COLD_P2_EXIT} turns=${COLD_P2_TURNS} cost=\$${COLD_P2_COST}"
echo "Duration: ${COLD_P2_START} → ${COLD_P2_END}"
echo ""

# ── Gate Check ──────────────────────────────────────────────────────
echo "================================================================"
echo "GATE CHECK"
echo "================================================================"

if [[ -f "${RESULTS_DIR}/nearmiss-cold-phase1-findings.md" ]]; then
  echo "--- Phase 1 findings (first 50 lines) ---"
  head -50 "${RESULTS_DIR}/nearmiss-cold-phase1-findings.md"
  echo "..."
fi
echo ""

if [[ -f "${RESULTS_DIR}/nearmiss-cold-phase2-fix.md" ]]; then
  echo "--- Phase 2 fix (first 40 lines) ---"
  head -40 "${RESULTS_DIR}/nearmiss-cold-phase2-fix.md"
  echo "..."
fi
echo ""

if [[ -f "${MEMORY_DIR}/${FP_HASH}.md" ]]; then
  echo "--- Memory file written ---"
  cat "${MEMORY_DIR}/${FP_HASH}.md"
fi

echo ""
echo "================================================================"
echo "COLD GATE SUMMARY"
echo "================================================================"
echo "Phase 1: exit=${COLD_P1_EXIT} turns=${COLD_P1_TURNS} cost=\$${COLD_P1_COST} (${COLD_P1_START} → ${COLD_P1_END})"
echo "Phase 2: exit=${COLD_P2_EXIT} turns=${COLD_P2_TURNS} cost=\$${COLD_P2_COST} (${COLD_P2_START} → ${COLD_P2_END})"
echo ""
echo "Check 1: Does Phase 1 identify stale-read/cache as root cause (NOT TOCTOU race)?"
echo "Check 2: Is Phase 2 fix cache invalidation (NOT mutex/atomic decrement)?"
echo "Review the output above and decide: PASS → proceed to Run 2, FAIL → stop."
echo "================================================================"
