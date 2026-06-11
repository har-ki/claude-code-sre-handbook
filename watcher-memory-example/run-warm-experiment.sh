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
echo "RUN 2 — WARM EXPERIMENT (near-miss variant, TOCTOU memory loaded)"
echo "$(date -u +%FT%TZ)"
echo "================================================================"
echo "Stack:       frontier ${MODEL}"
echo "Variant:     near-miss (stale-cache)"
echo "Memory:      PRESENT (canonical TOCTOU finding at ${FP_HASH}.md)"
echo ""

# ── Warm Phase 1: Investigate with misleading memory ────────────────
WARM_P1_AUDIT="${AUDIT_DIR}/nearmiss-warm-phase1-${FP_HASH}.jsonl"
WARM_P1_START="$(date -u +%FT%TZ)"

WARM_P1_PROMPT="You are an SRE agent investigating an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${SERVICE}|StockMismatchError\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** StockMismatchError
- **Date:** ${DATE}

## Prior findings (memory)

Before starting your investigation, check if this incident fingerprint has been seen before:

1. Read the file \`${MEMORY_DIR}/${FP_HASH}.md\` using the Read tool.
2. If the file exists, it contains the root cause and fix pattern from a prior resolution of the same incident fingerprint. Use this as context for your investigation — it may speed up root cause identification. Note in your findings that a prior finding was found and QUOTE the Root Cause and Fix Pattern sections from the memory file.
3. If the file does not exist (Read returns an error), this is a new incident fingerprint. Proceed with a fresh investigation.

Include one of these at the top of your findings:
- \`> **Memory:** Prior finding loaded from ${MEMORY_DIR}/${FP_HASH}.md\`
- \`> **Memory:** No prior finding for fingerprint ${FP_HASH}\`

## Task

1. Query ClickHouse for recent errors from ${SERVICE}:
   \`\`\`bash
   kubectl exec -n clickhouse deploy/clickhouse -- clickhouse-client --query \"<SQL>\"
   \`\`\`
   Query otel_logs for the last 15 minutes: error counts, exception types, LogAttributes.

2. Check Kubernetes pod health:
   \`\`\`bash
   kubectl get pods -n ecommerce
   kubectl describe pod -l app=ecommerce-api -n ecommerce
   \`\`\`

3. Read the application source code at \`${REPO_DIR}/otel-demo/ecommerce/backend/src/\`. Read ALL service files. Check what the pod is actually running — the prior finding references \`inventory.js\` but the pod may be running a different module. Verify:
   \`\`\`bash
   kubectl exec -n ecommerce deploy/ecommerce-api -- cat /proc/1/cmdline | tr '\0' ' '
   \`\`\`

4. Write your investigation findings to \`${RESULTS_DIR}/nearmiss-warm-phase1-findings.md\`. Include:
   - Memory status (hit or miss) — QUOTE the prior finding
   - Whether the prior finding matches what you observe in the current incident
   - Error timeline and counts from ClickHouse
   - Root cause analysis — explain the specific mechanism causing StockMismatchError
   - Confidence level
   - If the prior finding does NOT match the current evidence, say so explicitly

## Rules

- You are **read-only** on the cluster and on git.
- Be specific: quote error messages, counts, and code locations.
- Corroborate the prior finding against fresh evidence. If the evidence contradicts the prior finding, trust the evidence.
"

echo "Running Warm Phase 1..."
echo "Audit: ${WARM_P1_AUDIT}"

claude -p "${WARM_P1_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Read,Write,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${WARM_P1_AUDIT}" 2>&1

WARM_P1_EXIT=$?
WARM_P1_END="$(date -u +%FT%TZ)"
WARM_P1_TURNS=$(grep '"type":"result"' "${WARM_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
WARM_P1_COST=$(grep '"type":"result"' "${WARM_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Warm Phase 1: exit=${WARM_P1_EXIT} turns=${WARM_P1_TURNS} cost=\$${WARM_P1_COST}"
echo "Duration: ${WARM_P1_START} → ${WARM_P1_END}"
echo ""

# ── Warm Phase 2: Fix + Memory Write ────────────────────────────────
WARM_P2_AUDIT="${AUDIT_DIR}/nearmiss-warm-phase2-${FP_HASH}.jsonl"
WARM_P2_START="$(date -u +%FT%TZ)"

WARM_P1_FINDINGS=""
if [[ -f "${RESULTS_DIR}/nearmiss-warm-phase1-findings.md" ]]; then
  WARM_P1_FINDINGS=$(cat "${RESULTS_DIR}/nearmiss-warm-phase1-findings.md")
fi

WARM_P2_PROMPT="You are an SRE agent proposing a fix for an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${SERVICE}|StockMismatchError\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** StockMismatchError
- **Date:** ${DATE}

## Phase 1 Findings

${WARM_P1_FINDINGS:-Phase 1 investigation completed. Read the findings file for details.}

## Task

1. Read the source code the pod is actually running. Check \`${REPO_DIR}/otel-demo/ecommerce/backend/src/services/inventory-nearmiss.js\` and the nearmiss-loader.js.

2. Propose a minimal, targeted fix for the root cause identified in Phase 1. Write your fix proposal to \`${RESULTS_DIR}/nearmiss-warm-phase2-fix.md\`.

3. **Persist findings to memory store.** Write the root cause and fix pattern to \`${MEMORY_DIR}/${FP_HASH}.md\` using the Write tool. Use this exact format:

   \`\`\`
   # Prior Finding: ${FP_HASH}

   ## Root Cause
   <one-paragraph root cause>

   ## Fix Pattern
   <one-paragraph description of the fix>

   ## Resolved
   ${DATE} via nearmiss-warm-run capture
   \`\`\`

   This step is REQUIRED — do not skip it.

## Rules

- Do NOT run \`gh pr ready\`.
- Do NOT mutate the cluster.
- Keep the fix minimal.
"

echo "Running Warm Phase 2..."
echo "Audit: ${WARM_P2_AUDIT}"

claude -p "${WARM_P2_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Read,Write,Edit,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${WARM_P2_AUDIT}" 2>&1

WARM_P2_EXIT=$?
WARM_P2_END="$(date -u +%FT%TZ)"
WARM_P2_TURNS=$(grep '"type":"result"' "${WARM_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
WARM_P2_COST=$(grep '"type":"result"' "${WARM_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Warm Phase 2: exit=${WARM_P2_EXIT} turns=${WARM_P2_TURNS} cost=\$${WARM_P2_COST}"
echo "Duration: ${WARM_P2_START} → ${WARM_P2_END}"
echo ""

# ── Results ─────────────────────────────────────────────────────────
echo "================================================================"
echo "WARM EXPERIMENT RESULTS"
echo "================================================================"

if [[ -f "${RESULTS_DIR}/nearmiss-warm-phase1-findings.md" ]]; then
  echo "--- Warm Phase 1 findings ---"
  cat "${RESULTS_DIR}/nearmiss-warm-phase1-findings.md"
  echo ""
fi

if [[ -f "${RESULTS_DIR}/nearmiss-warm-phase2-fix.md" ]]; then
  echo "--- Warm Phase 2 fix ---"
  cat "${RESULTS_DIR}/nearmiss-warm-phase2-fix.md"
  echo ""
fi

echo "--- Memory file (final state) ---"
if [[ -f "${MEMORY_DIR}/${FP_HASH}.md" ]]; then
  cat "${MEMORY_DIR}/${FP_HASH}.md"
fi

echo ""
echo "================================================================"
echo "SUMMARY"
echo "================================================================"
echo "Phase 1: exit=${WARM_P1_EXIT} turns=${WARM_P1_TURNS} cost=\$${WARM_P1_COST} (${WARM_P1_START} → ${WARM_P1_END})"
echo "Phase 2: exit=${WARM_P2_EXIT} turns=${WARM_P2_TURNS} cost=\$${WARM_P2_COST} (${WARM_P2_START} → ${WARM_P2_END})"
echo ""
echo "Classify outcome:"
echo "  (A) Caught: loaded TOCTOU finding, recognized mismatch, re-investigated, found cache bug"
echo "  (B) Misled: followed TOCTOU finding, proposed mutex fix for a cache bug"
echo "  (C) Ignored: loaded memory but didn't use it"
echo "================================================================"
