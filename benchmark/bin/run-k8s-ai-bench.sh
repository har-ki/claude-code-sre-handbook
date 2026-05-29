#!/usr/bin/env bash
# run-k8s-ai-bench.sh — orchestrator for running Claude Code against k8s-ai-bench
#
# Usage:
#   ./benchmark/bin/run-k8s-ai-bench.sh [OPTIONS]
#
# Options:
#   --iterations N        Number of iterations for Pass@1/5/^5 (default: 5)
#   --model MODEL         Claude model to use (default: system default)
#   --task-pattern PAT    Regex to filter tasks (e.g. "fix-.*")
#   --cluster-provider P  kind or vcluster (default: kind)
#   --concurrency N       Parallel tasks (default: 1)
#   --skill               Inject K8s system prompt (default)
#   --no-skill            Run without K8s system prompt
#   --both                Run both skill and no-skill variants
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_DIR="${REPO_ROOT}/.build/k8s-ai-bench"
AGENT_BIN="${REPO_ROOT}/benchmark/bin/claude-agent.sh"

# Defaults
ITERATIONS=1
MODEL=""
TASK_PATTERN=""
CLUSTER_PROVIDER="kind"
CONCURRENCY=1
SKILL_MODE="skill"  # skill | noskill | both

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --iterations)   ITERATIONS="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    --task-pattern) TASK_PATTERN="$2"; shift 2 ;;
    --cluster-provider) CLUSTER_PROVIDER="$2"; shift 2 ;;
    --concurrency)  CONCURRENCY="$2"; shift 2 ;;
    --skill)        SKILL_MODE="skill"; shift ;;
    --no-skill)     SKILL_MODE="noskill"; shift ;;
    --both)         SKILL_MODE="both"; shift ;;
    --help|-h)
      head -15 "$0" | tail -13
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Prerequisites ---
check_prereq() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: $1 is required but not found in PATH" >&2
    exit 1
  fi
}

check_prereq claude
check_prereq docker
check_prereq kind
check_prereq kubectl
check_prereq go

GO_VERSION=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | sed 's/go//')
GO_MAJOR=$(echo "${GO_VERSION}" | cut -d. -f1)
GO_MINOR=$(echo "${GO_VERSION}" | cut -d. -f2)
if [[ "${GO_MAJOR}" -lt 1 ]] || { [[ "${GO_MAJOR}" -eq 1 ]] && [[ "${GO_MINOR}" -lt 21 ]]; }; then
  echo "ERROR: Go 1.21+ required, found ${GO_VERSION}" >&2
  exit 1
fi

echo "=== Prerequisites OK ==="

# --- Clone and build k8s-ai-bench ---
if [[ ! -d "${BENCH_DIR}/repo" ]]; then
  echo "=== Cloning k8s-ai-bench ==="
  mkdir -p "${BENCH_DIR}"
  git clone https://github.com/gke-labs/k8s-ai-bench.git "${BENCH_DIR}/repo"
fi

echo "=== Building k8s-ai-bench ==="
mkdir -p "${BENCH_DIR}/bin"
(cd "${BENCH_DIR}/repo" && go build -o "${BENCH_DIR}/bin/k8s-ai-bench" .)

# --- Handle gatekeeper directory nesting ---
# k8s-ai-bench has tasks/gatekeeper/ with sub-tasks that need flattening
TASKS_DIR="${BENCH_DIR}/repo/tasks"
if [[ -d "${TASKS_DIR}/gatekeeper" ]]; then
  for sub in "${TASKS_DIR}/gatekeeper"/*/; do
    if [[ -d "${sub}" ]]; then
      base=$(basename "${sub}")
      target="${TASKS_DIR}/gatekeeper-${base}"
      if [[ ! -d "${target}" ]]; then
        cp -r "${sub}" "${target}"
        echo "  Flattened: gatekeeper/${base} -> gatekeeper-${base}"
      fi
    fi
  done
  # Remove the parent so k8s-ai-bench doesn't try to load it as a task
  rm -rf "${TASKS_DIR}/gatekeeper"
  echo "  Removed original gatekeeper/ directory"
fi

# --- Ensure agent script is executable ---
chmod +x "${AGENT_BIN}"

# --- Run function ---
run_benchmark() {
  local skill_tag="$1"  # "skill" or "noskill"
  local timestamp
  timestamp=$(date +%Y%m%dT%H%M%S)

  local model_slug="${MODEL:-default}"
  model_slug=$(echo "${model_slug}" | tr './' '-')
  local run_dir="${REPO_ROOT}/benchmark/data/runs/${timestamp}_${model_slug}_${skill_tag}"
  mkdir -p "${run_dir}"

  # Set environment for the agent adapter
  if [[ "${skill_tag}" == "skill" ]]; then
    export CLAUDE_AGENT_SKILL=1
  else
    export CLAUDE_AGENT_SKILL=0
  fi

  if [[ -n "${MODEL}" ]]; then
    export CLAUDE_MODEL="${MODEL}"
  else
    unset CLAUDE_MODEL 2>/dev/null || true
  fi

  echo ""
  echo "=============================================="
  echo "  k8s-ai-bench: ${skill_tag} mode"
  echo "  Model: ${MODEL:-system-default}"
  echo "  Iterations: ${ITERATIONS}"
  echo "  Output: ${run_dir}"
  echo "=============================================="
  echo ""

  # Build k8s-ai-bench args
  local bench_args=(
    run
    --agent-bin "${AGENT_BIN}"
    --tasks-dir "${BENCH_DIR}/repo/tasks"
    --cluster-provider "${CLUSTER_PROVIDER}"
  )

  # Label results with correct provider/model metadata
  bench_args+=(--llm-provider "anthropic")
  bench_args+=(--models "${MODEL:-claude-default}")

  if [[ -n "${TASK_PATTERN}" ]]; then
    bench_args+=(--task-pattern "${TASK_PATTERN}")
  fi

  bench_args+=(--concurrency "${CONCURRENCY}")

  # Run iterations
  for i in $(seq 1 "${ITERATIONS}"); do
    local iter_dir="${run_dir}/iteration-${i}"
    mkdir -p "${iter_dir}"

    echo ""
    echo "--- Iteration ${i}/${ITERATIONS} (${skill_tag}) ---"
    echo ""

    "${BENCH_DIR}/bin/k8s-ai-bench" "${bench_args[@]}" \
      --output-dir "${iter_dir}" \
      2>&1 | tee "${iter_dir}/bench.log"

    echo ""
    echo "--- Iteration ${i} complete ---"
  done

  # Analyze results
  echo ""
  echo "=== Analyzing results: ${skill_tag} ==="
  "${REPO_ROOT}/benchmark/bin/analyze-results.sh" \
    --input-dir "${run_dir}" \
    --output-dir "${REPO_ROOT}/benchmark/data/raw" \
    --analysis-dir "${REPO_ROOT}/benchmark/analysis" \
    --model "${model_slug}" \
    --skill-tag "${skill_tag}" \
    --timestamp "${timestamp}"
}

# --- Main execution ---
case "${SKILL_MODE}" in
  skill)
    run_benchmark "skill"
    ;;
  noskill)
    run_benchmark "noskill"
    ;;
  both)
    run_benchmark "skill"
    run_benchmark "noskill"
    ;;
esac

echo ""
echo "=== Done ==="
echo "Results: ${REPO_ROOT}/benchmark/data/"
echo "Analysis: ${REPO_ROOT}/benchmark/analysis/"
