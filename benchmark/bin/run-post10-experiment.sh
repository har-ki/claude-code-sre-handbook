#!/usr/bin/env bash
# run-post10-experiment.sh — run the Post 10 runbook-as-context experiment
#
# Usage:
#   ./benchmark/bin/run-post10-experiment.sh --arm A|B|C [--runs 3] [--model sonnet]
#   ./benchmark/bin/run-post10-experiment.sh --all [--runs 3] [--model sonnet]
#
# Arms:
#   A — No skill (bare agent, minimal preamble only)
#   B — Thin skill (location hints, no phase structure)
#   C — Full runbook (three-phase investigate/corroborate/conclude)
#
# Requires: claude CLI, kubectl, kind cluster with otel-demo deployed
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILTER_SCRIPT="${REPO_ROOT}/benchmark/bin/stream-json-filter.py"
THIN_SKILL="${REPO_ROOT}/skills/post-10-runbook-experiment/thin-skill.md"
FULL_RUNBOOK="${REPO_ROOT}/skills/post-10-runbook-experiment/full-runbook.md"

# Defaults
ARM=""
RUNS=3
MODEL="sonnet"
RUN_ALL=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --arm)       ARM="$2"; shift 2 ;;
    --runs)      RUNS="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --all)       RUN_ALL=true; shift ;;
    --help|-h)
      head -13 "$0" | tail -11
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "${RUN_ALL}" == false && -z "${ARM}" ]]; then
  echo "ERROR: specify --arm A|B|C or --all" >&2
  exit 1
fi

# --- Prerequisites ---
check_prereq() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: $1 is required but not found in PATH" >&2
    exit 1
  fi
}

check_prereq claude
check_prereq kubectl
check_prereq python3

# Verify cluster and otel-demo are running
echo "=== Checking prerequisites ==="

if ! kubectl get namespace ecommerce &>/dev/null; then
  echo "ERROR: ecommerce namespace not found. Run otel-demo/setup.sh first." >&2
  exit 1
fi

# Wait up to 60s for a Running ecommerce-api pod (handles post-rollout restart race)
ECOMMERCE_READY=""
for _attempt in $(seq 1 12); do
  ECOMMERCE_READY=$(kubectl get pods -n ecommerce -l app=ecommerce-api \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [[ "${ECOMMERCE_READY}" == "Running" ]]; then break; fi
  sleep 5
done
if [[ "${ECOMMERCE_READY}" != "Running" ]]; then
  echo "ERROR: ecommerce-api pod is not running after 60s (status: ${ECOMMERCE_READY:-not found})" >&2
  exit 1
fi

# Check ClickHouse has recent data
CH_POD=$(kubectl get pod -n clickhouse -l app=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "${CH_POD}" ]]; then
  echo "ERROR: ClickHouse pod not found in clickhouse namespace" >&2
  exit 1
fi

LOG_COUNT=$(kubectl exec -n clickhouse "${CH_POD}" -- clickhouse client --query \
  "SELECT count() FROM otel_logs WHERE ServiceName='ecommerce-api' AND Timestamp >= now() - INTERVAL 5 MINUTE" 2>/dev/null || echo "0")
if [[ "${LOG_COUNT}" -lt 1 ]]; then
  echo "WARNING: No recent otel_logs from ecommerce-api. Data may not be flowing." >&2
fi

echo "  Cluster: OK"
echo "  ecommerce-api: Running"
echo "  ClickHouse logs (last 5m): ${LOG_COUNT}"
echo ""

# --- Alert prompt (identical for all arms) ---
ALERT_PROMPT="StockMismatchError alerts are firing on the ecommerce-api service in the ecommerce namespace. Customers are seeing checkout failures. Investigate the root cause.

You have access to:
- kubectl (KUBECONFIG is set)
- ClickHouse for OTel observability data — access via:
    kubectl exec -n clickhouse \$(kubectl get pod -n clickhouse -l app=clickhouse -o jsonpath='{.items[0].metadata.name}') -- clickhouse client --query \"SQL\"
- Application source code at ${REPO_ROOT}/otel-demo/ecommerce/backend/src/

Do not stop at the first plausible explanation. Verify your hypothesis by cross-referencing at least two signal types (logs, traces, code). State the root cause with evidence."

# --- Build system prompt for a given arm ---
build_system_prompt() {
  local arm="$1"
  case "${arm}" in
    A)
      echo "You have access to a Kubernetes cluster via kubectl. KUBECONFIG is set. ClickHouse is available in the cluster for querying OTel data. Complete the task autonomously. Do not ask questions."
      ;;
    B)
      if [[ ! -f "${THIN_SKILL}" ]]; then
        echo "ERROR: Thin skill not found at ${THIN_SKILL}" >&2
        exit 1
      fi
      cat "${THIN_SKILL}"
      ;;
    C)
      if [[ ! -f "${FULL_RUNBOOK}" ]]; then
        echo "ERROR: Full runbook not found at ${FULL_RUNBOOK}" >&2
        exit 1
      fi
      cat "${FULL_RUNBOOK}"
      ;;
    *)
      echo "ERROR: Unknown arm '${arm}'. Use A, B, or C." >&2
      exit 1
      ;;
  esac
}

# --- Run a single experiment ---
run_single() {
  local arm="$1"
  local run_num="$2"
  local run_dir="$3"

  mkdir -p "${run_dir}"

  local system_prompt
  system_prompt=$(build_system_prompt "${arm}")

  echo "  Starting run ${run_num} (Arm ${arm})..."
  echo "  Output: ${run_dir}"

  # Capture start time
  local start_ts
  start_ts=$(date +%s)

  # Invoke Claude from /tmp to avoid CLAUDE.md and auto-memory discovery
  # (cwd determines project-memory path; /tmp has no .claude/ ancestor)
  PYTHONUNBUFFERED=1 echo "${ALERT_PROMPT}" | \
    (cd /tmp && claude -p \
      --dangerously-skip-permissions \
      --max-budget-usd 10 \
      --allowedTools "Bash" \
      --model "${MODEL}" \
      --append-system-prompt "${system_prompt}" \
      --output-format stream-json --verbose) \
    | python3 "${FILTER_SCRIPT}" "${run_dir}/trace.jsonl" \
    > "${run_dir}/transcript.txt" 2>&1

  local end_ts
  end_ts=$(date +%s)
  local elapsed=$(( end_ts - start_ts ))

  echo "  Run ${run_num} complete (${elapsed}s wall time)"
  echo ""
}

# --- Reset incident state between runs ---
reset_incident() {
  echo "  Resetting ecommerce-api (restart pod to reset in-memory inventory)..."
  kubectl rollout restart deployment/ecommerce-api -n ecommerce >/dev/null 2>&1
  kubectl rollout status deployment/ecommerce-api -n ecommerce --timeout=60s >/dev/null 2>&1

  # Wait for OTel data to flow from the fresh pod
  echo "  Waiting 30s for OTel data to land..."
  sleep 30
}

# --- Run all iterations for one arm ---
run_arm() {
  local arm="$1"
  local timestamp
  timestamp=$(date +%Y%m%dT%H%M%S)

  local model_slug
  model_slug=$(echo "${MODEL}" | tr './' '-')
  local arm_dir="${REPO_ROOT}/benchmark/data/runs/${timestamp}_${model_slug}_canonical-${arm}"
  mkdir -p "${arm_dir}"

  echo ""
  echo "=============================================="
  local arm_label
  case ${arm} in A) arm_label="No Skill";; B) arm_label="Thin Skill";; C) arm_label="Full Runbook";; esac
  echo "  Arm ${arm} — ${arm_label}"
  echo "  Model: ${MODEL}"
  echo "  Runs: ${RUNS}"
  echo "  Output: ${arm_dir}"
  echo "=============================================="
  echo ""

  for i in $(seq 1 "${RUNS}"); do
    if [[ "${i}" -gt 1 ]]; then
      reset_incident
    fi
    run_single "${arm}" "${i}" "${arm_dir}/run-${i}"
  done

  echo "=== Arm ${arm} complete ==="
  echo ""
}

# --- Main execution ---
if [[ "${RUN_ALL}" == true ]]; then
  for arm in A B C; do
    run_arm "${arm}"
    # Reset between arms too
    if [[ "${arm}" != "C" ]]; then
      reset_incident
    fi
  done
else
  run_arm "${ARM}"
fi

echo ""
echo "=== Experiment complete ==="
echo "Results: ${REPO_ROOT}/benchmark/data/runs/"
echo "Run analysis: python3 ${REPO_ROOT}/benchmark/bin/analyze-post10.py ${REPO_ROOT}/benchmark/data/runs/<run-dir>"
