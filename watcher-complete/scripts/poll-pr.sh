#!/usr/bin/env bash
#
# Poll a PR until it reaches a terminal state (merged or closed), then
# invoke the learning phase. Secondary trigger path for local/air-gapped
# environments where the GitHub Action isn't wired.
#
# Usage: ./poll-pr.sh <pr_number> <fp_hash> <fingerprint> <github_repo>
#
set -euo pipefail

PR_NUM="${1:?Usage: poll-pr.sh <pr_num> <fp_hash> <fingerprint> <github_repo>}"
FP_HASH="${2:?fp_hash required}"
FINGERPRINT="${3:?fingerprint required}"
GITHUB_REPO="${4:?github_repo required}"

POLL_INTERVAL="${POLL_INTERVAL:-60}"

echo "Polling PR #${PR_NUM} in ${GITHUB_REPO} every ${POLL_INTERVAL}s..."

while true; do
  PR_STATE=$(gh pr view "$PR_NUM" --repo "$GITHUB_REPO" --json state,merged -q '{state: .state, merged: .merged}' 2>/dev/null)

  STATE=$(echo "$PR_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state'])" 2>/dev/null || echo "UNKNOWN")
  MERGED=$(echo "$PR_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['merged'])" 2>/dev/null || echo "False")

  echo "[$(date -u +%FT%TZ)] PR #${PR_NUM}: state=${STATE} merged=${MERGED}"

  if [[ "$STATE" == "CLOSED" && "$MERGED" == "False" ]]; then
    echo "PR closed without merging. Invoking learning phase with outcome=closed_unmerged."
    OUTCOME="closed_unmerged"
    break
  elif [[ "$MERGED" == "True" ]]; then
    OUTCOME="merged"
    echo "PR merged. Invoking learning phase with outcome=${OUTCOME}."
    break
  fi

  sleep "$POLL_INTERVAL"
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export FP_HASH FINGERPRINT PR_NUM GITHUB_REPO OUTCOME
exec "$SCRIPT_DIR/invoke-learn.sh"
