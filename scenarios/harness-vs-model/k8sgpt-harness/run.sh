#!/usr/bin/env bash
# Runs the k8sgpt-style fixed-harness experiment.
#
# Extracts the pod error string (the way k8sgpt's Pod analyzer does),
# wraps it in k8sgpt's exact prompt template, and sends it to the
# Anthropic Messages API.
#
# Requires: ANTHROPIC_API_KEY, kubectl, curl, jq
# Usage:    ./run.sh [--model claude-sonnet-4-20250514]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSCRIPT_DIR="${SCRIPT_DIR}/../transcripts"
MODEL="claude-sonnet-4-20250514"

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --model) MODEL="$2"; shift 2 ;;
    *) echo "usage: $0 [--model MODEL_ID]"; exit 1 ;;
  esac
done

# ── Preflight ────────────────────────────────────────────────────────────────

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "error: ANTHROPIC_API_KEY is not set" >&2
  exit 1
fi

for cmd in kubectl curl jq; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "error: ${cmd} is required but not found" >&2
    exit 1
  fi
done

# ── Extract pod error (replicating k8sgpt's Pod analyzer) ───────────────────

echo "[..] extracting pod error from cluster..."

# k8sgpt reads containerStatus.state.waiting.message for waiting pods
ERROR_MSG=$(kubectl get pod -n ecommerce -l app=checkout \
  -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.message}' 2>/dev/null || echo "")

# If the pod is between restarts (not in waiting state), fall back to
# lastState.terminated info — k8sgpt does this too
if [ -z "${ERROR_MSG}" ]; then
  TERM_REASON=$(kubectl get pod -n ecommerce -l app=checkout \
    -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")
  TERM_EXIT=$(kubectl get pod -n ecommerce -l app=checkout \
    -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || echo "")
  ERROR_MSG="back-off restarting failed container: ${TERM_REASON} (exit code ${TERM_EXIT})"
fi

echo "[ok] error string: ${ERROR_MSG}"

# ── Construct k8sgpt prompt ─────────────────────────────────────────────────
# Exact template from k8sgpt pkg/ai/prompts.go (default_prompt)

PROMPT="Simplify the following Kubernetes error message delimited by triple dashes written in --- english --- language; --- ${ERROR_MSG} ---.
Provide the most possible solution in a step by step style in no more than 280 characters. Write the output in the following format:
Error: {Explain error here}
Solution: {Step by step solution here}"

echo ""
echo "--- k8sgpt-style prompt ---"
echo "${PROMPT}"
echo "---"
echo ""

# ── Send to Anthropic API ───────────────────────────────────────────────────

echo "[..] sending to ${MODEL}..."

RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$(jq -n \
    --arg model "${MODEL}" \
    --arg prompt "${PROMPT}" \
    '{
      model: $model,
      max_tokens: 1024,
      messages: [{role: "user", content: $prompt}]
    }')")

# ── Save transcript ─────────────────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TRANSCRIPT_FILE="${TRANSCRIPT_DIR}/k8sgpt-style-${TIMESTAMP}.json"

jq -n \
  --arg ts "${TIMESTAMP}" \
  --arg model "${MODEL}" \
  --arg error_msg "${ERROR_MSG}" \
  --arg prompt "${PROMPT}" \
  --argjson response "${RESPONSE}" \
  '{
    experiment: "harness-vs-model",
    harness: "k8sgpt-style",
    timestamp: $ts,
    model: $model,
    error_string: $error_msg,
    prompt: $prompt,
    response: $response
  }' > "${TRANSCRIPT_FILE}"

echo "[ok] transcript saved: ${TRANSCRIPT_FILE}"

# ── Print response ──────────────────────────────────────────────────────────

echo ""
echo "=== Model Response (${MODEL}) ==="
echo ""
echo "${RESPONSE}" | jq -r '.content[0].text // .error.message // "no response"'
echo ""
