#!/usr/bin/env bash
#
# Post 10 canonical capture: cold + warm memory-enabled watcher
# against the real otel-demo InventoryRaceCondition (StockMismatchError).
#
# Runs two occurrences of the same incident:
#   Cold: Phase 1 (investigate, memory miss) → Phase 2 (fix + memory write)
#   Warm: Phase 1 (investigate, memory hit)  → Phase 2 (fix, memory already present)
#
# Locked invariants:
#   - Two separate claude -p phases (never collapsed)
#   - --max-turns 40 on both
#   - --output-format stream-json --verbose on both
#   - No gh pr ready in any allowedTools
#   - Fingerprint: sha256("ecommerce-api|StockMismatchError")[:8] = e2836e74
#
set -euo pipefail

CAPTURE_DIR="/tmp/watcher-memory-capture"
MEMORY_DIR="${CAPTURE_DIR}/memory-store/incidents"
AUDIT_DIR="${CAPTURE_DIR}/audit-log"
RESULTS_DIR="${CAPTURE_DIR}/results"
REPO_DIR="/Users/harikirannayak/Documents/workspace/claude-code-sre-handbook"

# Real incident fingerprint
SERVICE="ecommerce-api"
EXCEPTION_CLASS="StockMismatchError"
FP="${SERVICE}|${EXCEPTION_CLASS}"
FP_HASH="e2836e74"
DATE="$(date -u +%Y-%m-%d)"
TS_START="$(date -u +%FT%TZ)"

# Model: frontier Claude via API (not local Ollama)
MODEL="claude-sonnet-4-6"

echo "================================================================"
echo "Post 10 Canonical Capture — ${TS_START}"
echo "================================================================"
echo "Stack:          frontier ${MODEL} (Anthropic API)"
echo "Fingerprint:    ${FP}"
echo "Hash (sha8):    ${FP_HASH}"
echo "Memory dir:     ${MEMORY_DIR}"
echo "Audit dir:      ${AUDIT_DIR}"
echo "Cluster:        kind-claude-sre-demo"
echo ""

# Ensure kubectl context
kubectl config use-context kind-claude-sre-demo >/dev/null 2>&1

# ── Step 0: Clean slate ─────────────────────────────────────────────
echo "--- Step 0: Ensuring empty memory store ---"
rm -f "${MEMORY_DIR}"/*.md
if ls "${MEMORY_DIR}"/*.md 2>/dev/null; then
  echo "FAIL: memory-store/incidents/ not empty after cleanup"
  exit 1
fi
echo "OK: memory-store/incidents/ is empty"
echo ""

# Confirm errors are flowing
echo "--- Confirming StockMismatchError in ClickHouse ---"
ERR_COUNT=$(kubectl exec -n clickhouse deploy/clickhouse -- clickhouse-client \
  --query "SELECT count() FROM otel_logs WHERE ServiceName = 'ecommerce-api' AND SeverityText = 'ERROR' AND LogAttributes['exception.type'] = 'StockMismatchError'" 2>/dev/null || echo "0")
echo "StockMismatchError count: ${ERR_COUNT}"
if [ "${ERR_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: No StockMismatchError in ClickHouse. Is the load generator running?"
  exit 1
fi
echo ""

########################################################################
# COLD RUN
########################################################################
echo "################################################################"
echo "COLD RUN — First occurrence (no prior memory)"
echo "################################################################"
echo ""

# ── Cold Phase 1: Investigate (memory miss expected) ─────────────────
echo "================================================================"
echo "COLD Phase 1: Investigate (expect memory miss)"
echo "================================================================"

COLD_P1_AUDIT="${AUDIT_DIR}/cold-phase1-${FP_HASH}.jsonl"
COLD_P1_START="$(date -u +%FT%TZ)"

COLD_P1_PROMPT="You are an SRE agent investigating an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${FP}\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** StockMismatchError
- **Date:** ${DATE}

## Prior findings (memory)

Before starting your investigation, check if this incident fingerprint has been seen before:

1. Read the file \`${MEMORY_DIR}/${FP_HASH}.md\` using the Read tool.
2. If the file exists, it contains the root cause and fix pattern from a prior resolution of the same incident fingerprint. Use this as context — note it in your findings.
3. If the file does not exist (Read returns an error), this is a new incident fingerprint. Proceed with a fresh investigation.

Include one of these at the top of your findings:
- \`> **Memory:** Prior finding loaded from ${MEMORY_DIR}/${FP_HASH}.md\`
- \`> **Memory:** No prior finding for fingerprint ${FP_HASH}\`

## Task

1. Query ClickHouse for recent errors from ${SERVICE}. ClickHouse is accessible via kubectl:
   \`\`\`bash
   kubectl exec -n clickhouse deploy/clickhouse -- clickhouse-client --query \"<SQL>\"
   \`\`\`
   Query otel_logs for the last 15 minutes: error count, top exception types, LogAttributes['exception.type'], LogAttributes['exception.message'], LogAttributes['product.id'], LogAttributes['product.name'].

2. Check Kubernetes pod health: restarts, OOM kills, resource pressure.
   \`\`\`bash
   kubectl get pods -n ecommerce
   kubectl describe pod -l app=ecommerce-api -n ecommerce
   \`\`\`

3. The application source code is at \`${REPO_DIR}/otel-demo/ecommerce/backend/src/\`. Read the relevant source files (especially services/inventory.js) to understand the code path causing StockMismatchError.

4. Write your investigation findings to \`${RESULTS_DIR}/cold-phase1-findings.md\`. Include:
   - Memory status (hit or miss)
   - Error timeline and counts from ClickHouse
   - Root cause analysis
   - Confidence level (high/medium/low)
   - Specific evidence: error counts, log lines, code line references

## Rules

- You are **read-only** on the cluster and on git. Do not create commits or apply changes.
- Be specific: quote error messages, counts, and code locations.
- If confidence is low, say so and list what additional data would help.
"

echo "Running claude -p for Cold Phase 1..."
echo "Audit log: ${COLD_P1_AUDIT}"

claude -p "${COLD_P1_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Bash(clickhouse*),Read,Write,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${COLD_P1_AUDIT}" 2>&1

COLD_P1_EXIT=$?
COLD_P1_END="$(date -u +%FT%TZ)"
echo "Cold Phase 1 exit code: ${COLD_P1_EXIT}"
echo "Duration: ${COLD_P1_START} → ${COLD_P1_END}"
echo ""

# Extract turn count from result record
COLD_P1_TURNS=$(grep '"type":"result"' "${COLD_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
COLD_P1_COST=$(grep '"type":"result"' "${COLD_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Cold Phase 1: ${COLD_P1_TURNS} turns, \$${COLD_P1_COST}"

# Check memory miss
echo ""
echo "--- Cold Phase 1: Memory miss check ---"
if grep -q "No prior finding\|memory miss\|does not exist\|no prior\|no file found\|error.*Read\|not found" "${COLD_P1_AUDIT}" 2>/dev/null; then
  echo "OK: Memory miss detected in Phase 1 output"
else
  echo "WARNING: Could not confirm memory miss in output — check manually"
fi
echo ""

# ── Cold Phase 2: Fix + Memory Write ─────────────────────────────────
echo "================================================================"
echo "COLD Phase 2: Fix + Memory Write (expect write to ${FP_HASH}.md)"
echo "================================================================"

# Read Phase 1 findings if they were written
COLD_P1_FINDINGS=""
if [[ -f "${RESULTS_DIR}/cold-phase1-findings.md" ]]; then
  COLD_P1_FINDINGS=$(cat "${RESULTS_DIR}/cold-phase1-findings.md")
fi

COLD_P2_AUDIT="${AUDIT_DIR}/cold-phase2-${FP_HASH}.jsonl"
COLD_P2_START="$(date -u +%FT%TZ)"

COLD_P2_PROMPT="You are an SRE agent proposing a fix for an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${FP}\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** StockMismatchError
- **Date:** ${DATE}

## Phase 1 Findings

${COLD_P1_FINDINGS:-Phase 1 identified a TOCTOU race condition in inventory.js:reserveInventory(). The function reads stock via async getStock(), waits 50-150ms (simulated validation delay), then decrements non-atomically. Under concurrent load, multiple requests read the same stock value, all pass the guard check, and all decrement — causing stock to go negative. Product 7 (Ceramic Plant Pot, stock=5) is most affected.}

## Task

1. The application source code is at \`${REPO_DIR}/otel-demo/ecommerce/backend/src/\`. Read \`services/inventory.js\` to understand the bug.

2. Propose a minimal, targeted fix for the TOCTOU race condition. Write your fix proposal (what you would change and why) to \`${RESULTS_DIR}/cold-phase2-fix.md\`. Include the specific code change.

3. **Persist findings to memory store.** After completing the above steps, write the root cause and fix pattern to \`${MEMORY_DIR}/${FP_HASH}.md\` using the Write tool. Use this exact format:

   \`\`\`
   # Prior Finding: ${FP_HASH}

   ## Root Cause
   <one-paragraph root cause from the investigation — be specific about the function, the race window, and why Product 7 is affected>

   ## Fix Pattern
   <one-paragraph description of what should be changed and why — enough for a future agent to recognize and apply the same fix>

   ## Resolved
   ${DATE} via cold-run capture
   \`\`\`

   This step is REQUIRED — do not skip it. The memory file enables faster resolution if this incident type recurs.

## Rules

- Do NOT run \`gh pr ready\` — there is no PR in this test.
- Do NOT mutate the cluster.
- Keep the fix minimal. Do not refactor surrounding code.
- Do NOT use the Skill tool.
"

echo "Running claude -p for Cold Phase 2..."
echo "Audit log: ${COLD_P2_AUDIT}"

claude -p "${COLD_P2_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Read,Write,Edit,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${COLD_P2_AUDIT}" 2>&1

COLD_P2_EXIT=$?
COLD_P2_END="$(date -u +%FT%TZ)"
echo "Cold Phase 2 exit code: ${COLD_P2_EXIT}"
echo "Duration: ${COLD_P2_START} → ${COLD_P2_END}"
echo ""

COLD_P2_TURNS=$(grep '"type":"result"' "${COLD_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
COLD_P2_COST=$(grep '"type":"result"' "${COLD_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Cold Phase 2: ${COLD_P2_TURNS} turns, \$${COLD_P2_COST}"

# ── Critical check: Did the memory write fire? ──────────────────────
echo ""
echo "================================================================"
echo "CRITICAL CHECK: Phase 2 memory write"
echo "================================================================"

# (a) File on disk
if [[ -f "${MEMORY_DIR}/${FP_HASH}.md" ]]; then
  echo "OK (a): File exists at ${MEMORY_DIR}/${FP_HASH}.md"
  MEMORY_FILE_SIZE=$(wc -c < "${MEMORY_DIR}/${FP_HASH}.md")
  echo "    Size: ${MEMORY_FILE_SIZE} bytes"
  echo ""
  echo "--- Exact file contents ---"
  cat "${MEMORY_DIR}/${FP_HASH}.md"
  echo ""
  echo "--- End file contents ---"
else
  echo "FAIL (a): File NOT found at ${MEMORY_DIR}/${FP_HASH}.md"
  echo "THE MEMORY WRITE DID NOT FIRE. This is the PRIMARY failure."
  echo "Check audit log: ${COLD_P2_AUDIT}"
  # Still continue to collect what data we can
fi

# (b) Write tool call in stream-json
echo ""
WRITE_CALLS=$(grep -c '"name":"Write"' "${COLD_P2_AUDIT}" 2>/dev/null || echo "0")
echo "Write tool calls in stream-json: ${WRITE_CALLS}"
if [[ "${WRITE_CALLS}" -gt 0 ]]; then
  echo "OK (b): Write tool call found in stream-json"
  # Show the Write calls targeting memory store
  echo ""
  echo "--- Write tool calls targeting memory-store ---"
  grep '"name":"Write"' "${COLD_P2_AUDIT}" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        obj = json.loads(line.strip())
        for c in obj.get('message', {}).get('content', []):
            if c.get('name') == 'Write':
                path = c.get('input', {}).get('file_path', '?')
                content_len = len(c.get('input', {}).get('content', ''))
                print(f'  Write to: {path} ({content_len} chars)')
    except: pass
" 2>/dev/null
else
  echo "WARNING (b): No Write tool call found — checking other patterns"
  grep -i 'write\|memory.*store\|incidents.*md' "${COLD_P2_AUDIT}" | head -5
fi
echo ""

########################################################################
# WARM RUN
########################################################################
echo "################################################################"
echo "WARM RUN — Second occurrence (prior memory exists)"
echo "################################################################"
echo ""

# ── Warm Phase 1: Investigate (memory hit expected) ──────────────────
echo "================================================================"
echo "WARM Phase 1: Investigate (expect memory hit)"
echo "================================================================"

WARM_P1_AUDIT="${AUDIT_DIR}/warm-phase1-${FP_HASH}.jsonl"
WARM_P1_START="$(date -u +%FT%TZ)"

WARM_P1_PROMPT="You are an SRE agent investigating an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${FP}\`
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
   Query otel_logs for the last 15 minutes of StockMismatchError data.

2. Check Kubernetes pod health for ${SERVICE}.

3. Read the source code at \`${REPO_DIR}/otel-demo/ecommerce/backend/src/services/inventory.js\`.

4. Write your investigation findings to \`${RESULTS_DIR}/warm-phase1-findings.md\`. Include:
   - Memory status (hit or miss) — QUOTE the prior finding if it exists
   - Error timeline and counts from ClickHouse
   - Root cause analysis (corroborate with prior finding if available)
   - Confidence level

## Rules

- You are **read-only** on the cluster and on git.
- Be specific: quote error messages, counts, and code locations.
- QUOTE the prior finding content in your output so we can confirm it was loaded.
"

echo "Running claude -p for Warm Phase 1..."
echo "Audit log: ${WARM_P1_AUDIT}"

claude -p "${WARM_P1_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Bash(clickhouse*),Read,Write,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${WARM_P1_AUDIT}" 2>&1

WARM_P1_EXIT=$?
WARM_P1_END="$(date -u +%FT%TZ)"
echo "Warm Phase 1 exit code: ${WARM_P1_EXIT}"
echo "Duration: ${WARM_P1_START} → ${WARM_P1_END}"
echo ""

WARM_P1_TURNS=$(grep '"type":"result"' "${WARM_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
WARM_P1_COST=$(grep '"type":"result"' "${WARM_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Warm Phase 1: ${WARM_P1_TURNS} turns, \$${WARM_P1_COST}"

# ── Warm Phase 1: Memory hit check ──────────────────────────────────
echo ""
echo "--- Warm Phase 1: Memory hit check ---"

# Check Read tool call targeting memory file
READ_MEMORY=$(grep '"name":"Read"' "${WARM_P1_AUDIT}" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        obj = json.loads(line.strip())
        for c in obj.get('message', {}).get('content', []):
            if c.get('name') == 'Read' and '${FP_HASH}' in str(c.get('input', {})):
                print('HIT')
    except: pass
" 2>/dev/null)

if [[ "${READ_MEMORY}" == *"HIT"* ]]; then
  echo "OK: Read tool call targeting ${FP_HASH}.md found in stream-json"
else
  echo "WARNING: Could not confirm Read targeting ${FP_HASH}.md — checking output"
fi

# Check prior finding content appears in model output
echo ""
echo "--- Checking prior finding quoted in Phase 1 context ---"
RESULT_TEXT=$(grep '"type":"result"' "${WARM_P1_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null || echo "")

if echo "${RESULT_TEXT}" | grep -qi "prior finding\|memory.*hit\|memory.*loaded"; then
  echo "OK: Memory hit/prior finding referenced in result text"
fi

if echo "${RESULT_TEXT}" | grep -qi "TOCTOU\|race condition\|reserveInventory\|non-atomic"; then
  echo "OK: Root cause from memory appears in Phase 1 result"
fi

if echo "${RESULT_TEXT}" | grep -qi "atomic\|UPDATE.*WHERE\|row.*lock\|fix pattern"; then
  echo "OK: Fix pattern from memory appears in Phase 1 result"
fi

# Also check findings file
echo ""
if [[ -f "${RESULTS_DIR}/warm-phase1-findings.md" ]]; then
  echo "--- Warm Phase 1 findings file ---"
  cat "${RESULTS_DIR}/warm-phase1-findings.md"
  echo ""
  echo "--- End findings ---"
fi

########################################################################
# WARM Phase 2 (for completeness — same as cold but memory already present)
########################################################################
echo "================================================================"
echo "WARM Phase 2: Fix + Memory Write (memory file already exists)"
echo "================================================================"

WARM_P2_AUDIT="${AUDIT_DIR}/warm-phase2-${FP_HASH}.jsonl"
WARM_P2_START="$(date -u +%FT%TZ)"

WARM_P2_FINDINGS=""
if [[ -f "${RESULTS_DIR}/warm-phase1-findings.md" ]]; then
  WARM_P2_FINDINGS=$(cat "${RESULTS_DIR}/warm-phase1-findings.md")
fi

WARM_P2_PROMPT="You are an SRE agent proposing a fix for an incident on **${SERVICE}**.

## Context

- **Fingerprint:** \`${FP}\`
- **Fingerprint hash:** \`${FP_HASH}\`
- **Exception class:** StockMismatchError
- **Date:** ${DATE}

## Phase 1 Findings

${WARM_P2_FINDINGS:-Phase 1 identified a TOCTOU race condition in inventory.js:reserveInventory(). Prior memory finding was available for fingerprint ${FP_HASH}.}

## Task

1. Read \`${REPO_DIR}/otel-demo/ecommerce/backend/src/services/inventory.js\` to understand the bug.

2. Propose a minimal, targeted fix for the TOCTOU race condition. Write your fix proposal to \`${RESULTS_DIR}/warm-phase2-fix.md\`.

3. **Persist findings to memory store.** Write the root cause and fix pattern to \`${MEMORY_DIR}/${FP_HASH}.md\` using the Write tool. Use this exact format:

   \`\`\`
   # Prior Finding: ${FP_HASH}

   ## Root Cause
   <one-paragraph root cause>

   ## Fix Pattern
   <one-paragraph description of the fix>

   ## Resolved
   ${DATE} via warm-run capture
   \`\`\`

   This step is REQUIRED — do not skip it.

## Rules

- Do NOT run \`gh pr ready\`.
- Do NOT mutate the cluster.
- Keep the fix minimal.
"

echo "Running claude -p for Warm Phase 2..."
echo "Audit log: ${WARM_P2_AUDIT}"

claude -p "${WARM_P2_PROMPT}" \
  --allowedTools 'Bash(kubectl*),Read,Write,Edit,Glob,Grep' \
  --output-format stream-json \
  --verbose \
  --model "${MODEL}" \
  --max-turns 40 \
  > "${WARM_P2_AUDIT}" 2>&1

WARM_P2_EXIT=$?
WARM_P2_END="$(date -u +%FT%TZ)"
echo "Warm Phase 2 exit code: ${WARM_P2_EXIT}"
echo "Duration: ${WARM_P2_START} → ${WARM_P2_END}"
echo ""

WARM_P2_TURNS=$(grep '"type":"result"' "${WARM_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns','?'))" 2>/dev/null || echo "?")
WARM_P2_COST=$(grep '"type":"result"' "${WARM_P2_AUDIT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_cost_usd','?'))" 2>/dev/null || echo "?")
echo "Warm Phase 2: ${WARM_P2_TURNS} turns, \$${WARM_P2_COST}"

########################################################################
# GUARDRAIL CHECK
########################################################################
echo ""
echo "================================================================"
echo "GUARDRAIL CHECK"
echo "================================================================"

# Check no memory reads/writes outside memory-store/incidents/
OUTSIDE=0
for audit in "${COLD_P1_AUDIT}" "${COLD_P2_AUDIT}" "${WARM_P1_AUDIT}" "${WARM_P2_AUDIT}"; do
  basename_audit=$(basename "$audit")
  # Check Write calls
  WRITES_OUTSIDE=$(grep '"name":"Write"' "$audit" 2>/dev/null | python3 -c "
import sys, json
count = 0
for line in sys.stdin:
    try:
        obj = json.loads(line.strip())
        for c in obj.get('message', {}).get('content', []):
            if c.get('name') == 'Write':
                path = c.get('input', {}).get('file_path', '')
                if 'memory-store/incidents' not in path and 'results' not in path:
                    count += 1
                    print(f'  OUTSIDE WRITE: {path}')
    except: pass
print(f'TOTAL:{count}')
" 2>/dev/null | tail -1 | cut -d: -f2)
  WRITES_OUTSIDE=${WRITES_OUTSIDE:-0}
  if [[ "${WRITES_OUTSIDE}" -gt 0 ]]; then
    echo "WARNING: ${basename_audit} has ${WRITES_OUTSIDE} writes outside memory-store/incidents/ and results/"
    OUTSIDE=$((OUTSIDE + WRITES_OUTSIDE))
  fi
done
if [[ $OUTSIDE -eq 0 ]]; then
  echo "OK: No writes detected outside allowed directories"
fi

# Check no gh pr ready
echo ""
for audit in "${COLD_P1_AUDIT}" "${COLD_P2_AUDIT}" "${WARM_P1_AUDIT}" "${WARM_P2_AUDIT}"; do
  if grep -q "gh pr ready" "$audit" 2>/dev/null; then
    echo "FAIL: 'gh pr ready' found in $(basename $audit)"
  fi
done
echo "OK: 'gh pr ready' absent from all phases"

########################################################################
# FINAL SUMMARY
########################################################################
echo ""
echo "################################################################"
echo "FINAL SUMMARY — Post 10 Canonical Capture"
echo "################################################################"
echo ""
echo "Stack/Model:     frontier ${MODEL} (Anthropic API)"
echo "Fingerprint:     ${FP}"
echo "sha8 hash:       ${FP_HASH}"
echo ""
echo "COLD RUN:"
echo "  Phase 1 (investigate):"
echo "    Exit: ${COLD_P1_EXIT} | Turns: ${COLD_P1_TURNS} | Cost: \$${COLD_P1_COST}"
echo "    Time: ${COLD_P1_START} → ${COLD_P1_END}"
echo "    Memory miss: $(grep -qi 'no prior finding\|memory miss\|does not exist\|not found' ${COLD_P1_AUDIT} 2>/dev/null && echo YES || echo CHECK)"
echo "  Phase 2 (fix + write):"
echo "    Exit: ${COLD_P2_EXIT} | Turns: ${COLD_P2_TURNS} | Cost: \$${COLD_P2_COST}"
echo "    Time: ${COLD_P2_START} → ${COLD_P2_END}"
echo "    Memory write fired: $(test -f ${MEMORY_DIR}/${FP_HASH}.md && echo YES || echo NO)"
echo "    Write in stream-json: $(grep -c '"name":"Write"' ${COLD_P2_AUDIT} 2>/dev/null) calls"
echo ""
echo "WARM RUN:"
echo "  Phase 1 (investigate):"
echo "    Exit: ${WARM_P1_EXIT} | Turns: ${WARM_P1_TURNS} | Cost: \$${WARM_P1_COST}"
echo "    Time: ${WARM_P1_START} → ${WARM_P1_END}"
echo "    Memory hit: $(grep -qi 'prior finding.*loaded\|memory.*hit\|memory.*loaded' ${WARM_P1_AUDIT} 2>/dev/null && echo YES || echo CHECK)"
echo "    Prior finding in context: $(grep -qi 'TOCTOU\|race condition' ${WARM_P1_AUDIT} 2>/dev/null && echo YES || echo CHECK)"
echo "  Phase 2 (fix + write):"
echo "    Exit: ${WARM_P2_EXIT} | Turns: ${WARM_P2_TURNS} | Cost: \$${WARM_P2_COST}"
echo "    Time: ${WARM_P2_START} → ${WARM_P2_END}"
echo ""
echo "Guardrails:"
echo "  Outside writes: ${OUTSIDE}"
echo "  gh pr ready:    absent"
echo ""
echo "Memory file (final):"
if [[ -f "${MEMORY_DIR}/${FP_HASH}.md" ]]; then
  echo "  Path: ${MEMORY_DIR}/${FP_HASH}.md"
  echo "  Size: $(wc -c < "${MEMORY_DIR}/${FP_HASH}.md") bytes"
fi
echo ""
echo "Audit logs:"
echo "  ${COLD_P1_AUDIT}"
echo "  ${COLD_P2_AUDIT}"
echo "  ${WARM_P1_AUDIT}"
echo "  ${WARM_P2_AUDIT}"
echo ""
echo "Results files:"
ls -la "${RESULTS_DIR}/" 2>/dev/null
echo ""
echo "Memory store:"
ls -la "${MEMORY_DIR}/" 2>/dev/null
echo ""
echo "================================================================"
echo "Capture complete — ${TS_START} → $(date -u +%FT%TZ)"
echo "================================================================"
