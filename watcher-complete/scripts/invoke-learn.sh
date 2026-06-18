#!/usr/bin/env bash
#
# Invokes the learning phase (Phase 3) for a merged or closed PR.
# Shared entrypoint for both the GitHub Action and the poll script.
#
# Required env: FP_HASH, FINGERPRINT, PR_NUM, GITHUB_REPO, OUTCOME
# Optional env: MODEL (default: claude-sonnet-4-6), MAX_TURNS (default: 10)
#
set -euo pipefail

: "${FP_HASH:?FP_HASH is required}"
: "${FINGERPRINT:?FINGERPRINT is required}"
: "${PR_NUM:?PR_NUM is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${OUTCOME:?OUTCOME is required (merged|merged_modified|closed_unmerged)}"
: "${MODEL:=claude-sonnet-4-6}"
: "${MAX_TURNS:=10}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MEMORY_FILE="${ROOT_DIR}/memory-store/incidents/${FP_HASH}.md"
if [[ ! -f "$MEMORY_FILE" ]]; then
  echo "ERROR: No finding at ${MEMORY_FILE} for fingerprint ${FP_HASH}" >&2
  exit 1
fi
ORIGINAL_FINDING=$(cat "$MEMORY_FILE")
export ORIGINAL_FINDING

# Get the merged diff from the PR
if [[ "$OUTCOME" == "closed_unmerged" ]]; then
  MERGED_DIFF="(PR closed without merging — no merged diff available)"
else
  MERGED_DIFF=$(gh pr diff "$PR_NUM" --repo "$GITHUB_REPO" 2>/dev/null || echo "(diff unavailable)")
fi
export MERGED_DIFF

export FP_HASH FINGERPRINT PR_NUM GITHUB_REPO OUTCOME

PROMPT_FILE="${ROOT_DIR}/prompts/03-learn.md"
RENDERED_PROMPT=$(envsubst < "$PROMPT_FILE")

ALLOWED_TOOLS='Bash(git diff*),Bash(git log*),Bash(gh pr view*),Read,Write,Glob,Grep'

LEARN_OUTPUT=$(claude -p "$RENDERED_PROMPT" \
  --allowedTools "$ALLOWED_TOOLS" \
  --model "$MODEL" \
  --max-turns "$MAX_TURNS" \
  --print 2>/dev/null)

echo "$LEARN_OUTPUT"

# Parse the JSON output and call record_outcome via Python.
# Write the output to a temp file to avoid shell injection from embedded quotes.
LEARN_JSON_FILE=$(mktemp)
trap 'rm -f "$LEARN_JSON_FILE"' EXIT

echo "$LEARN_OUTPUT" > "$LEARN_JSON_FILE"

python3 - "$LEARN_JSON_FILE" "${ROOT_DIR}" "${FP_HASH}" "${OUTCOME}" <<'PYEOF'
import sys, json, os, re

json_file, root_dir, fp_hash, fallback_outcome = sys.argv[1:5]

sys.path.insert(0, os.path.join(root_dir, 'alert-watcher'))
os.environ['MEMORY_INCIDENTS_DIR'] = os.path.join(root_dir, 'memory-store', 'incidents')
os.environ['SQLITE_DB_PATH'] = os.path.join(root_dir, 'memory-store', 'embeddings', 'findings.db')

from store import create_backend

with open(json_file) as f:
    text = f.read()

# Find the last JSON object in the output (handles nested braces)
data = None
for match in re.finditer(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', text):
    try:
        data = json.loads(match.group())
    except json.JSONDecodeError:
        continue

if data is None:
    print("WARNING: Could not parse learning phase output as JSON", file=sys.stderr)
    sys.exit(1)

backend = create_backend('sqlite')
ok = backend.record_outcome(
    fp_hash,
    data.get('outcome', fallback_outcome),
    data.get('verdict', ''),
    data.get('lesson', '')
)
print(f'record_outcome: {"success" if ok else "finding not found"}')
PYEOF

# Audit log
AUDIT_DIR="${ROOT_DIR}/audit-log"
mkdir -p "$AUDIT_DIR"
AUDIT_FILE="${AUDIT_DIR}/phase3-${FP_HASH}-$(date -u +%Y%m%dT%H%M%SZ).json"
cat > "$AUDIT_FILE" <<EOF
{
  "phase": 3,
  "fp_hash": "${FP_HASH}",
  "fingerprint": "${FINGERPRINT}",
  "pr_num": ${PR_NUM},
  "outcome": "${OUTCOME}",
  "timestamp": "$(date -u +%FT%TZ)",
  "raw_output_length": ${#LEARN_OUTPUT}
}
EOF
echo "Audit logged to ${AUDIT_FILE}"
