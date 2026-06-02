#!/usr/bin/env bash
# run-memory-test.sh — probe and test Claude Code memory tool behavior
#
# Entrypoint for the Phase 10 memory-tool test harness.
# Takes a profile + step/phase/tier, writes JSONL to benchmark/data/raw/.
#
# Usage:
#   ./run-memory-test.sh --profile profiles/sonnet.env --step 1
#   ./run-memory-test.sh --profile profiles/sonnet.env --step 2 --tier implicit --iterations 5
#   ./run-memory-test.sh --profile profiles/sonnet.env --step 2 --phase 1 --tier explicit --iterations 1
#
set -euo pipefail

# ── Path resolution ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FILTER_SCRIPT="${REPO_ROOT}/benchmark/bin/stream-json-filter.py"
PARSER_SCRIPT="${SCRIPT_DIR}/parse-memory-trace.py"
MEMORIES_DIR="${SCRIPT_DIR}/memories"
RAW_DATA_DIR="${REPO_ROOT}/benchmark/data/raw"

# ── Argument defaults ───────────────────────────────────────────────────
PROFILE=""
STEP=""
PHASE="both"
TIER=""
ITERATIONS=5

# ── Argument parsing ────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") --profile <path> --step <1|2> [options]

Options:
  --profile <path>       Path to profile .env file (required)
  --step <1|2>           1 = stack probe, 2 = drive test (required)
  --phase <1|2|both>     Phase for step 2 (default: both)
  --tier <implicit|explicit>  Tier for step 2 (required for step 2)
  --iterations <N>       Number of iterations for step 2 (default: 5)
  --help                 Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)    PROFILE="$2"; shift 2 ;;
    --step)       STEP="$2"; shift 2 ;;
    --phase)      PHASE="$2"; shift 2 ;;
    --tier)       TIER="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --help)       usage ;;
    *)            echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ── Validate arguments ──────────────────────────────────────────────────
[[ -z "${PROFILE}" ]] && { echo "ERROR: --profile is required" >&2; usage; }
[[ -z "${STEP}" ]] && { echo "ERROR: --step is required" >&2; usage; }
[[ ! -f "${PROFILE}" ]] && { echo "ERROR: Profile not found: ${PROFILE}" >&2; exit 1; }
[[ "${STEP}" != "1" && "${STEP}" != "2" ]] && { echo "ERROR: --step must be 1 or 2" >&2; exit 1; }

if [[ "${STEP}" == "2" ]]; then
  [[ -z "${TIER}" ]] && { echo "ERROR: --tier is required for step 2" >&2; usage; }
  [[ "${TIER}" != "implicit" && "${TIER}" != "explicit" ]] && { echo "ERROR: --tier must be implicit or explicit" >&2; exit 1; }
  [[ "${PHASE}" != "1" && "${PHASE}" != "2" && "${PHASE}" != "both" ]] && { echo "ERROR: --phase must be 1, 2, or both" >&2; exit 1; }
fi

# ── Prerequisite checks ─────────────────────────────────────────────────
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude not found in PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found in PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found in PATH" >&2; exit 1; }
[[ -f "${FILTER_SCRIPT}" ]] || { echo "ERROR: stream-json-filter.py not found at ${FILTER_SCRIPT}" >&2; exit 1; }
[[ -f "${PARSER_SCRIPT}" ]] || { echo "ERROR: parse-memory-trace.py not found at ${PARSER_SCRIPT}" >&2; exit 1; }

# ── Source profile ───────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "${PROFILE}"
export MODEL="${MODEL:?MODEL must be set in profile}"
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
  export ANTHROPIC_BASE_URL
fi

# ── Capture metadata ────────────────────────────────────────────────────
CLAUDE_CODE_VERSION=$(claude --version 2>/dev/null | head -1 || echo "unknown")
DATE_STAMP=$(date +%Y%m%d)
TIMESTAMP=$(date +%Y%m%dT%H%M%S)

# Slugify model name for filenames (replace colons/slashes with dashes)
MODEL_SLUG=$(echo "${MODEL}" | tr ':/' '-')

echo "==> Profile: ${PROFILE}"
echo "==> Model: ${MODEL} (slug: ${MODEL_SLUG})"
echo "==> Claude Code version: ${CLAUDE_CODE_VERSION}"

# ── Ensure output directories exist ─────────────────────────────────────
mkdir -p "${RAW_DATA_DIR}"

# ── Helper: build claude args ───────────────────────────────────────────
build_claude_args() {
  CLAUDE_ARGS=(
    -p
    --dangerously-skip-permissions
    --output-format stream-json
    --verbose
    --model "${MODEL}"
  )
  if [[ "${MAX_BUDGET_USD:-0}" != "0" ]]; then
    CLAUDE_ARGS+=(--max-budget-usd "${MAX_BUDGET_USD}")
  fi
}

# ── Helper: run claude with a prompt, capture trace ─────────────────────
run_claude_capture() {
  local prompt="$1"
  local trace_jsonl="$2"
  local work_dir="${3:-${SCRIPT_DIR}}"

  build_claude_args

  echo "    Running claude with model=${MODEL}..."
  PYTHONUNBUFFERED=1 echo "${prompt}" \
    | (cd "${work_dir}" && claude "${CLAUDE_ARGS[@]}") \
    | python3 "${FILTER_SCRIPT}" "${trace_jsonl}" \
    > /dev/null 2>&1 || true

  if [[ ! -f "${trace_jsonl}" ]]; then
    echo "    WARNING: trace.jsonl not created at ${trace_jsonl}" >&2
    return 1
  fi
  echo "    Trace captured: ${trace_jsonl} ($(wc -l < "${trace_jsonl}") lines)"
}

# ── Helper: reset memories directory ────────────────────────────────────
reset_memories() {
  find "${MEMORIES_DIR}" -type f ! -name '.gitkeep' ! -name '.gitignore' -delete 2>/dev/null || true
  echo "    Memories directory reset"
}

# ── Helper: write JSONL line ────────────────────────────────────────────
write_jsonl() {
  local json_data="$1"
  local output_file="$2"
  echo "${json_data}" >> "${output_file}"
  echo "    JSONL written: ${output_file}"
}


# ════════════════════════════════════════════════════════════════════════
# Step 1: Stack Probe
# ════════════════════════════════════════════════════════════════════════
if [[ "${STEP}" == "1" ]]; then
  echo ""
  echo "# ── Step 1: Stack Capability Probe ──────────────────────────────"
  echo ""

  TRACE_DIR=$(mktemp -d)
  trap 'rm -rf "${TRACE_DIR}"' EXIT
  TRACE_JSONL="${TRACE_DIR}/trace.jsonl"

  PROBE_PROMPT="Check your memory directory and tell me what's there."

  run_claude_capture "${PROBE_PROMPT}" "${TRACE_JSONL}"

  # Parse the trace for memory tool signals
  PROBE_RESULT=$(python3 "${PARSER_SCRIPT}" "${TRACE_JSONL}" stack-probe)
  echo "    Probe result: ${PROBE_RESULT}"

  # Merge with metadata
  OUTPUT_FILE="${RAW_DATA_DIR}/${DATE_STAMP}-T-memtest-${MODEL_SLUG}-stack-probe.jsonl"
  FULL_RESULT=$(echo "${PROBE_RESULT}" | jq -c \
    --arg ts "${TIMESTAMP}" \
    --arg model "${MODEL}" \
    --arg ccv "${CLAUDE_CODE_VERSION}" \
    --arg profile "$(basename "${PROFILE}" .env)" \
    '. + {timestamp: $ts, model: $model, step: "stack-probe", claude_code_version: $ccv, profile: $profile}')

  write_jsonl "${FULL_RESULT}" "${OUTPUT_FILE}"

  # Hard stop check for Ollama path
  TOOL_PRESENT=$(echo "${PROBE_RESULT}" | jq -r '.tool_type_present')
  if [[ "${TOOL_PRESENT}" == "false" ]]; then
    IS_LOCAL=$(echo "${ANTHROPIC_BASE_URL:-}" | grep -c "localhost" || true)
    if [[ "${IS_LOCAL}" -gt 0 ]]; then
      echo ""
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║  HARD STOP: Memory tool NOT exposed via Ollama path.       ║"
      echo "║  This is finding (a) — a stack finding.                    ║"
      echo "║  Do NOT proceed to Step 2 for this profile.               ║"
      echo "║  The raw stream-json is captured; the negative is the     ║"
      echo "║  result. Post 12 likely becomes the honest-limits piece.  ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      echo ""
      # Copy trace to raw data for archival
      cp "${TRACE_JSONL}" "${RAW_DATA_DIR}/${DATE_STAMP}-T-memtest-${MODEL_SLUG}-stack-probe-trace.jsonl"
      exit 0
    fi
    echo ""
    echo "WARNING: Memory tool not found in tools list for API profile."
    echo "This may indicate a Claude Code version or flag issue."
    echo "Check: --dangerously-skip-permissions may suppress memory tool."
    echo ""
  else
    echo ""
    echo "==> Memory tool found in tools list. Step 2 is a go."
    echo ""
  fi

  echo "==> Step 1 complete."
  exit 0
fi


# ════════════════════════════════════════════════════════════════════════
# Step 2: Two-Tier, Two-Phase Drive Test
# ════════════════════════════════════════════════════════════════════════
if [[ "${STEP}" == "2" ]]; then
  echo ""
  echo "# ── Step 2: Drive Test (tier=${TIER}, phase=${PHASE}, iterations=${ITERATIONS}) ──"
  echo ""

  # Determine which phases to run
  PHASES_TO_RUN=()
  if [[ "${PHASE}" == "both" ]]; then
    PHASES_TO_RUN=(1 2)
  else
    PHASES_TO_RUN=("${PHASE}")
  fi

  for i in $(seq 1 "${ITERATIONS}"); do
    echo ""
    echo "  ── Iteration ${i}/${ITERATIONS} ────────────────────────────────"

    # Reset memories at the start of each full iteration
    if [[ "${PHASE}" == "both" || "${PHASE}" == "1" ]]; then
      reset_memories
    fi

    TRACE_DIR=$(mktemp -d)

    for p in "${PHASES_TO_RUN[@]}"; do
      echo ""
      echo "    Phase ${p} (${TIER})..."

      # Select prompt file
      if [[ "${p}" == "1" ]]; then
        PROMPT_FILE="${SCRIPT_DIR}/prompts/01-write-${TIER}.md"
      else
        PROMPT_FILE="${SCRIPT_DIR}/prompts/02-recall-${TIER}.md"
      fi

      if [[ ! -f "${PROMPT_FILE}" ]]; then
        echo "ERROR: Prompt file not found: ${PROMPT_FILE}" >&2
        exit 1
      fi

      PROMPT=$(cat "${PROMPT_FILE}")
      TRACE_JSONL="${TRACE_DIR}/phase${p}-iter${i}.jsonl"

      run_claude_capture "${PROMPT}" "${TRACE_JSONL}"

      # Parse trace for drive-test signals
      DRIVE_RESULT=$(python3 "${PARSER_SCRIPT}" "${TRACE_JSONL}" drive-test)
      echo "    Drive result: ${DRIVE_RESULT}"

      # For phase 2, determine 'recalled' from the trace
      RECALLED="null"
      if [[ "${p}" == "2" ]]; then
        # recalled = model made at least one memory read call
        TOOL_CALLS=$(echo "${DRIVE_RESULT}" | jq -r '.tool_calls')
        CHECKED=$(echo "${DRIVE_RESULT}" | jq -r '.checked_first')
        if [[ "${TOOL_CALLS}" -gt 0 && "${CHECKED}" == "true" ]]; then
          RECALLED="true"
        else
          RECALLED="false"
        fi
      fi

      # Build full JSONL line
      OUTPUT_FILE="${RAW_DATA_DIR}/${DATE_STAMP}-T-memtest-${MODEL_SLUG}-drive-${TIER}-phase${p}.jsonl"
      ITER_TIMESTAMP=$(date +%Y%m%dT%H%M%S)

      FULL_RESULT=$(echo "${DRIVE_RESULT}" | jq -c \
        --arg ts "${ITER_TIMESTAMP}" \
        --arg model "${MODEL}" \
        --arg ccv "${CLAUDE_CODE_VERSION}" \
        --arg tier "${TIER}" \
        --argjson phase "${p}" \
        --argjson iteration "${i}" \
        --argjson recalled "${RECALLED}" \
        --arg profile "$(basename "${PROFILE}" .env)" \
        '. + {timestamp: $ts, model: $model, step: "drive-test", tier: $tier, phase: $phase, iteration: $iteration, recalled: $recalled, claude_code_version: $ccv, profile: $profile}')

      write_jsonl "${FULL_RESULT}" "${OUTPUT_FILE}"

      # Archive trace for representative transcript selection
      ARCHIVE_TRACE="${RAW_DATA_DIR}/${DATE_STAMP}-T-memtest-${MODEL_SLUG}-drive-${TIER}-phase${p}-iter${i}-trace.jsonl"
      cp "${TRACE_JSONL}" "${ARCHIVE_TRACE}"

    done

    rm -rf "${TRACE_DIR}"
  done

  echo ""
  echo "==> Step 2 complete. Results in: ${RAW_DATA_DIR}/"
  echo ""
  exit 0
fi
