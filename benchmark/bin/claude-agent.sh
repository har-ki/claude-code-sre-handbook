#!/usr/bin/env bash
# claude-agent.sh — adapter that k8s-ai-bench invokes as the "agent binary"
#
# k8s-ai-bench calls:  claude-agent.sh --kubeconfig <path> [other flags]
#                       with the task prompt on stdin
#
# This script translates that into a `claude -p` invocation.
set -euo pipefail

KUBECONFIG_PATH=""
TRACE_PATH=""

# Parse flags — only care about --kubeconfig and --trace-path, ignore the rest
while [[ $# -gt 0 ]]; do
  case $1 in
    --kubeconfig)
      KUBECONFIG_PATH="$2"; shift 2 ;;
    --trace-path)
      TRACE_PATH="$2"; shift 2 ;;
    # Boolean flags from k8s-ai-bench (no value)
    --quiet|--skip-permissions|--show-tool-output|--enable-tool-use-shim|--mcp-client)
      shift ;;
    # Key-value flags from k8s-ai-bench (skip both flag and value)
    --llm-provider|--model|--models)
      shift 2 ;;
    *)
      shift ;;
  esac
done

# Determine trace output paths from --trace-path
# k8s-ai-bench sets --trace-path to {outputDir}/{taskID}/trace.yaml
if [[ -n "${TRACE_PATH}" ]]; then
  TASK_OUTPUT_DIR="$(dirname "${TRACE_PATH}")"
  TRACE_JSONL="${TASK_OUTPUT_DIR}/trace.jsonl"
  BENCHMARK_TASK_NAME="$(basename "${TASK_OUTPUT_DIR}")"
else
  TRACE_JSONL="/tmp/trace-$$.jsonl"
  BENCHMARK_TASK_NAME="unknown"
fi

# Write task name for inference proxy correlation
if [[ -n "${BENCHMARK_TASK_NAME_FILE:-}" ]]; then
  echo "${BENCHMARK_TASK_NAME}" > "${BENCHMARK_TASK_NAME_FILE}"
fi

# Read the task prompt from stdin
PROMPT=$(cat)

if [[ -z "${PROMPT}" ]]; then
  echo "ERROR: No prompt received on stdin" >&2
  exit 1
fi

# Export KUBECONFIG so kubectl works inside Claude Code's Bash tool
if [[ -n "${KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

# Build claude command
CLAUDE_ARGS=(
  -p
  --dangerously-skip-permissions
  --max-budget-usd 10
  --allowedTools "Bash"
)

# Inject K8s skill if skill mode is enabled
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="${SCRIPT_DIR}/../../skills/k8s/SKILL.md"

if [[ "${CLAUDE_AGENT_SKILL:-0}" == "1" ]]; then
  if [[ -f "${SKILL_FILE}" ]]; then
    SYSTEM_PROMPT="You have access to a Kubernetes cluster via kubectl.
KUBECONFIG is set in your environment — kubectl commands will work directly.

$(cat "${SKILL_FILE}")

Complete the task autonomously. Do not ask questions."
    CLAUDE_ARGS+=(--append-system-prompt "${SYSTEM_PROMPT}")
  else
    echo "WARNING: Skill mode enabled but ${SKILL_FILE} not found" >&2
  fi
else
  # No skill — minimal context only
  CLAUDE_ARGS+=(--append-system-prompt "You have access to a Kubernetes cluster via kubectl. KUBECONFIG is set in your environment. Complete the task autonomously. Do not ask questions.")
fi

# Capture structured tool-call trace alongside human-readable output
CLAUDE_ARGS+=(--output-format stream-json --verbose)

# Pass model override if set by orchestrator
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  CLAUDE_ARGS+=(--model "${CLAUDE_MODEL}")
fi

# Invoke Claude Code, piping stream-json through filter to produce
# both trace.jsonl (raw structured data) and stdout (prose for log.txt)
FILTER_SCRIPT="${SCRIPT_DIR}/stream-json-filter.py"
PYTHONUNBUFFERED=1 echo "${PROMPT}" | claude "${CLAUDE_ARGS[@]}" \
  | python3 "${FILTER_SCRIPT}" "${TRACE_JSONL}"
