#!/usr/bin/env bash
set -euo pipefail

CAP="/tmp/post11-matrix"
MEM="${CAP}/memory-store/incidents"
AUD="${CAP}/audit-log"
RES="${CAP}/results"
REPO="/Users/harikirannayak/Documents/workspace/claude-code-sre-handbook"
MODEL="claude-sonnet-4-6"
DATE="$(date -u +%Y-%m-%d)"

FINDING=$(cat "${MEM}/e2836e74.md")

run_phase1() {
  local TAG="$1" SERVICE="$2" EXC="$3" FINDING_CONTENT="$4" SIM_SCORE="$5" DISCIPLINE="$6"
  local AUDIT="${AUD}/${TAG}-phase1.jsonl"
  local FP_HASH
  FP_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${SERVICE}|${EXC}'.encode()).hexdigest()[:8])")

  local DISC_BLOCK=""
  if [[ "$DISCIPLINE" == "on" ]]; then
    DISC_BLOCK="
### Validation discipline

**You MUST explicitly classify the prior finding before using it.** State one of:
- \`> **Validation: VALIDATED** — prior finding matches current evidence because <reason>\`
- \`> **Validation: INVALIDATED** — prior finding does NOT match current evidence because <reason>\`
- \`> **Validation: INCONCLUSIVE** — cannot confirm or deny yet; investigating further\`

If INVALIDATED, do NOT use the prior finding. Investigate from scratch.
If VALIDATED, use it as starting hypothesis and corroborate with fresh evidence."
  fi

  local MEM_BLOCK=""
  if [[ -n "$FINDING_CONTENT" ]]; then
    MEM_BLOCK="> **Memory:** Prior finding loaded (similarity mode, score=${SIM_SCORE}, matched hash e2836e74)

### Quoted Prior Finding
${FINDING_CONTENT}
${DISC_BLOCK}"
  else
    MEM_BLOCK="> **Memory:** No prior finding for fingerprint ${FP_HASH}"
  fi

  local PROMPT="You are an SRE agent investigating an incident on **${SERVICE}**.

## Context
- **Fingerprint:** \`${SERVICE}|${EXC}\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** ${EXC}
- **Date:** ${DATE}

## Prior findings (memory)

${MEM_BLOCK}

## Task

1. Query ClickHouse for recent errors from ${SERVICE}:
   \`\`\`bash
   kubectl exec -n clickhouse deploy/clickhouse -- clickhouse-client --query \"<SQL>\"
   \`\`\`
   Query otel_logs for the last 15 minutes.

2. Check Kubernetes pod health:
   \`\`\`bash
   kubectl get pods -n ecommerce
   kubectl describe pod -l app=ecommerce-api -n ecommerce
   \`\`\`

3. Read the application source code at \`${REPO}/otel-demo/ecommerce/backend/src/\`. Check what the pod is actually running:
   \`\`\`bash
   kubectl exec -n ecommerce deploy/ecommerce-api -- cat /proc/1/cmdline | tr '\0' ' '
   \`\`\`
   Read ALL inventory service files.

4. Write investigation findings to \`${RES}/${TAG}-phase1-findings.md\`. Include:
   - Memory status and validation classification (if discipline is active)
   - Error timeline from ClickHouse
   - Root cause analysis
   - Confidence level
   - Whether the prior finding matches or contradicts what you observe

## Rules
- Read-only on cluster and git.
- Be specific: quote error messages, counts, code locations.
"

  echo "  Running ${TAG} Phase 1 (discipline=${DISCIPLINE})..."
  claude -p "${PROMPT}" \
    --allowedTools 'Bash(kubectl*),Read,Write,Glob,Grep' \
    --output-format stream-json --verbose \
    --model "${MODEL}" --max-turns 40 \
    > "${AUDIT}" 2>&1
  local EXIT=$?
  local TURNS COST
  TURNS=$(grep '"type":"result"' "${AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
  COST=$(grep '"type":"result"' "${AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
  echo "  → exit=${EXIT} turns=${TURNS} cost=\$${COST}"
}

run_phase2() {
  local TAG="$1" SERVICE="$2" FP_HASH="$3"
  local AUDIT="${AUD}/${TAG}-phase2.jsonl"
  local P1_FINDINGS=""
  if [[ -f "${RES}/${TAG}-phase1-findings.md" ]]; then
    P1_FINDINGS=$(cat "${RES}/${TAG}-phase1-findings.md")
  fi

  local PROMPT="You are an SRE agent proposing a fix for an incident on **${SERVICE}**.

## Context
- **Fingerprint hash:** \`${FP_HASH}\`
- **Date:** ${DATE}

## Phase 1 Findings
${P1_FINDINGS:-Phase 1 findings not available.}

## Task
1. Read the source code the pod is running at \`${REPO}/otel-demo/ecommerce/backend/src/\`.
2. Propose a minimal fix. Write to \`${RES}/${TAG}-phase2-fix.md\`.
3. **Persist findings to memory store.** Write to \`${MEM}/${FP_HASH}.md\` using the Write tool:
   \`\`\`
   # Prior Finding: ${FP_HASH}
   ## Root Cause
   <one paragraph>
   ## Fix Pattern
   <one paragraph>
   ## Resolved
   ${DATE} via post11-matrix ${TAG}
   \`\`\`
   This step is REQUIRED.

## Rules
- Do NOT run gh pr ready. Do NOT mutate the cluster. Keep the fix minimal.
"

  echo "  Running ${TAG} Phase 2..."
  claude -p "${PROMPT}" \
    --allowedTools 'Bash(kubectl*),Read,Write,Edit,Glob,Grep' \
    --output-format stream-json --verbose \
    --model "${MODEL}" --max-turns 40 \
    > "${AUDIT}" 2>&1
  local EXIT=$?
  local TURNS COST
  TURNS=$(grep '"type":"result"' "${AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
  COST=$(grep '"type":"result"' "${AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
  echo "  → exit=${EXIT} turns=${TURNS} cost=\$${COST}"
}

echo "================================================================"
echo "POST 11 EXPERIMENT MATRIX — $(date -u +%FT%TZ)"
echo "Stack: frontier ${MODEL}"
echo "================================================================"
echo ""

########################################################################
# CELL 1: Drift + similarity + discipline OFF (canonical cluster)
# Shows: similarity rescues what exact missed
########################################################################
echo "── CELL 1: Drift, similarity, discipline OFF ──"
run_phase1 "drift-sim-off" "ecommerce-api" "InventoryValidationError" "${FINDING}" "0.81" "off"
echo ""

########################################################################
# CELL 2: Canonical + similarity + discipline ON (canonical cluster)
# Control: discipline validates a correct match
########################################################################
echo "── CELL 2: Canonical, similarity, discipline ON ──"
run_phase1 "canonical-sim-on" "ecommerce-api" "StockMismatchError" "${FINDING}" "0.80" "on"
echo ""

########################################################################
# CELL 3: Drift + similarity + discipline ON (canonical cluster)
# Shows: discipline validates a correct cross-name match
########################################################################
echo "── CELL 3: Drift, similarity, discipline ON ──"
run_phase1 "drift-sim-on" "ecommerce-api" "InventoryValidationError" "${FINDING}" "0.81" "on"
echo ""

########################################################################
# Switch to near-miss variant
########################################################################
echo "── Switching to near-miss otel-demo variant ──"
kubectl apply -f "${REPO}/otel-demo/k8s/ecommerce-nearmiss.yaml" 2>&1
kubectl rollout restart deploy/ecommerce-api -n ecommerce 2>&1
echo "  Waiting for rollout + errors..."
kubectl rollout status deploy/ecommerce-api -n ecommerce --timeout=120s 2>&1
sleep 30
kubectl exec -n clickhouse deploy/clickhouse -- clickhouse-client \
  --query "SELECT LogAttributes['exception.type'] AS exc, count() FROM otel_logs WHERE SeverityText='ERROR' AND Timestamp >= now() - INTERVAL 1 MINUTE GROUP BY exc" 2>/dev/null
echo ""

########################################################################
# CELL 4: Near-miss + similarity + discipline OFF
# Shows: agent gets anchored (same as exact — the wall)
########################################################################
echo "── CELL 4: Near-miss, similarity, discipline OFF ──"
run_phase1 "nearmiss-sim-off" "ecommerce-api" "StockMismatchError" "${FINDING}" "0.80" "off"
run_phase2 "nearmiss-sim-off" "ecommerce-api" "e2836e74"
echo ""

########################################################################
# CELL 5: Near-miss + similarity + discipline ON — THE KEY TEST
# Shows: does discipline catch the near-miss?
########################################################################
echo "── CELL 5: Near-miss, similarity, discipline ON ── THE KEY TEST"
run_phase1 "nearmiss-sim-on" "ecommerce-api" "StockMismatchError" "${FINDING}" "0.80" "on"
run_phase2 "nearmiss-sim-on" "ecommerce-api" "e2836e74"
echo ""

########################################################################
# SUMMARY
########################################################################
echo "================================================================"
echo "MATRIX COMPLETE — $(date -u +%FT%TZ)"
echo "================================================================"
echo ""
echo "Audit logs:"
ls -la "${AUD}/"
echo ""
echo "Results:"
ls -la "${RES}/"
echo ""
echo "Memory store (final):"
ls -la "${MEM}/"
echo ""

# Extract key results
for tag in drift-sim-off canonical-sim-on drift-sim-on nearmiss-sim-off nearmiss-sim-on; do
  echo "── ${tag} ──"
  if [[ -f "${RES}/${tag}-phase1-findings.md" ]]; then
    # Show validation classification if present
    grep -i "Validation:" "${RES}/${tag}-phase1-findings.md" 2>/dev/null | head -3 || echo "  (no validation classification)"
    # Show memory status
    grep -i "Memory:" "${RES}/${tag}-phase1-findings.md" 2>/dev/null | head -1 || true
  fi
  echo ""
done
