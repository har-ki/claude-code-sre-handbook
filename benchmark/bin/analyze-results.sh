#!/usr/bin/env bash
# analyze-results.sh — compute Pass@1/5/^5 metrics from k8s-ai-bench results
#
# Usage:
#   ./benchmark/bin/analyze-results.sh \
#     --input-dir <run-dir> \
#     --output-dir <jsonl-dir> \
#     --analysis-dir <summary-dir> \
#     --model <model-slug> \
#     --skill-tag <skill|noskill> \
#     --timestamp <YYYYMMDDTHHMMSS>
set -euo pipefail

INPUT_DIR=""
OUTPUT_DIR=""
ANALYSIS_DIR=""
MODEL=""
SKILL_TAG=""
TIMESTAMP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --input-dir)    INPUT_DIR="$2"; shift 2 ;;
    --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
    --analysis-dir) ANALYSIS_DIR="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    --skill-tag)    SKILL_TAG="$2"; shift 2 ;;
    --timestamp)    TIMESTAMP="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${INPUT_DIR}" || -z "${OUTPUT_DIR}" || -z "${MODEL}" ]]; then
  echo "ERROR: --input-dir, --output-dir, and --model are required" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${ANALYSIS_DIR}"

DATE_PART=$(echo "${TIMESTAMP}" | cut -dT -f1)
JSONL_PREFIX="${DATE_PART}-T-${MODEL}-${SKILL_TAG}"
SUMMARY_FILE="${ANALYSIS_DIR}/${TIMESTAMP}-${MODEL}-${SKILL_TAG}-summary.md"

# --- Collect results into a temp file: "task iteration result" per line ---
RESULTS_TMP=$(mktemp)
trap 'rm -f "${RESULTS_TMP}"' EXIT

iteration_count=0
for iter_dir in "${INPUT_DIR}"/iteration-*/; do
  [[ -d "${iter_dir}" ]] || continue
  iteration_count=$((iteration_count + 1))

  for task_dir in "${iter_dir}"/*/; do
    [[ -d "${task_dir}" ]] || continue
    task_name=$(basename "${task_dir}")

    # Parse result from k8s-ai-bench results.yaml
    # Format: "result: success" or "result: fail" or "result: error" or "result: """
    result="fail"
    if [[ -f "${task_dir}/results.yaml" ]]; then
      raw=$(grep -E '^result:' "${task_dir}/results.yaml" 2>/dev/null | head -1 | awk '{print $2}')
      if [[ "${raw}" == "success" ]]; then
        result="pass"
      fi
    fi

    echo "${task_name} ${iteration_count} ${result}" >> "${RESULTS_TMP}"
  done
done

if [[ ${iteration_count} -eq 0 ]]; then
  echo "WARNING: No iteration directories found in ${INPUT_DIR}" >&2
  exit 0
fi

# --- Get unique task names ---
task_list=$(awk '{print $1}' "${RESULTS_TMP}" | sort -u)

# --- Compute metrics and write JSONL + summary ---
total_tasks=0
pass_at_1_count=0
pass_at_5_count=0
pass_all_count=0

{
  echo "# Benchmark Results: ${MODEL} (${SKILL_TAG})"
  echo ""
  echo "- **Timestamp:** ${TIMESTAMP}"
  echo "- **Model:** ${MODEL}"
  echo "- **Mode:** ${SKILL_TAG}"
  echo "- **Iterations:** ${iteration_count}"
  echo ""
  echo "| Task | Pass@1 | Pass@5 | Pass^5 | Results |"
  echo "|------|--------|--------|--------|---------|"
} > "${SUMMARY_FILE}"

for task in ${task_list}; do
  total_tasks=$((total_tasks + 1))

  # Get results for this task, sorted by iteration
  task_results=$(grep "^${task} " "${RESULTS_TMP}" | sort -k2 -n | awk '{print $3}')

  # Pass@1: first iteration passed
  pass1="fail"
  first_result=$(echo "${task_results}" | head -1)
  if [[ "${first_result}" == "pass" ]]; then
    pass1="pass"
    pass_at_1_count=$((pass_at_1_count + 1))
  fi

  # Pass@5: any iteration passed
  pass5="fail"
  if echo "${task_results}" | grep -q "^pass$"; then
    pass5="pass"
    pass_at_5_count=$((pass_at_5_count + 1))
  fi

  # Pass^5: all iterations passed
  pass_all="pass"
  if echo "${task_results}" | grep -q -v "^pass$"; then
    pass_all="fail"
  fi
  if [[ "${pass_all}" == "pass" ]]; then
    pass_all_count=$((pass_all_count + 1))
  fi

  # Write JSONL — one line per iteration
  iter_num=0
  for r in ${task_results}; do
    iter_num=$((iter_num + 1))
    echo "{\"timestamp\":\"${TIMESTAMP}\",\"model\":\"${MODEL}\",\"skill\":\"${SKILL_TAG}\",\"task\":\"${task}\",\"iteration\":${iter_num},\"result\":\"${r}\"}"
  done >> "${OUTPUT_DIR}/${JSONL_PREFIX}-${task}.jsonl"

  # Summary row
  results_str=$(echo "${task_results}" | tr '\n' ' ')
  echo "| ${task} | ${pass1} | ${pass5} | ${pass_all} | ${results_str}|" >> "${SUMMARY_FILE}"
done

# --- Aggregate summary ---
{
  echo ""
  echo "## Aggregate"
  echo ""
  echo "| Metric | Count | Rate |"
  echo "|--------|-------|------|"
  if [[ ${total_tasks} -gt 0 ]]; then
    echo "| Pass@1 | ${pass_at_1_count}/${total_tasks} | $(( pass_at_1_count * 100 / total_tasks ))% |"
    echo "| Pass@5 | ${pass_at_5_count}/${total_tasks} | $(( pass_at_5_count * 100 / total_tasks ))% |"
    echo "| Pass^5 | ${pass_all_count}/${total_tasks} | $(( pass_all_count * 100 / total_tasks ))% |"
  fi
} >> "${SUMMARY_FILE}"

echo "Summary written to: ${SUMMARY_FILE}"
echo "JSONL written to: ${OUTPUT_DIR}/${JSONL_PREFIX}-*.jsonl"

# Print summary to stdout
echo ""
echo "=== Results: ${MODEL} (${SKILL_TAG}) ==="
echo "  Pass@1: ${pass_at_1_count}/${total_tasks}"
echo "  Pass@5: ${pass_at_5_count}/${total_tasks}"
echo "  Pass^5: ${pass_all_count}/${total_tasks}"
