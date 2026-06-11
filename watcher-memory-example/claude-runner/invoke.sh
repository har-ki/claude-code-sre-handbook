#!/usr/bin/env bash
#
# Invokes Claude Code headless for a single phase of an incident.
# Memory-enabled variant: /memory-store/incidents/ is mounted for
# per-incident memory read (Phase 1) and write (Phase 2).
#
# Required env: PHASE, FP, FP_HASH, FINGERPRINT, SERVICE, RATE_PCT,
#               PR_NUM, GITHUB_REPO, MODEL, DATE
# Phase 1 also uses: PRIOR_FINDING (content from memory, may be empty)
# Phase 2 also needs: ROOT_CAUSE, EVIDENCE, DETECTION
#
set -euo pipefail

: "${PHASE:?PHASE is required (1 or 2)}"
: "${MODEL:=claude-sonnet-4-6}"
: "${MAX_TURNS:=40}"

# Resolve prompt file
PROMPT_DIR="${PROMPT_DIR:-/prompts}"
PROMPT_FILE=$(ls "${PROMPT_DIR}"/0"${PHASE}"-*.md 2>/dev/null | head -1)
if [[ -z "$PROMPT_FILE" ]]; then
  echo '{"ts":"'"$(date -u +%FT%TZ)"'","error":"no prompt file for phase '"${PHASE}"'"}' >&2
  exit 1
fi

# envsubst the prompt
RENDERED_PROMPT=$(envsubst < "$PROMPT_FILE")

# Phase-specific allowedTools
# Note: Read and Write tools handle memory-store access — no Bash filter
# widening needed. gh pr ready is deliberately absent from both phases.
if [[ "$PHASE" == "1" ]]; then
  ALLOWED_TOOLS='Bash(clickhouse client*),Bash(kubectl get*),Bash(kubectl describe*),Bash(kubectl logs*),Bash(kubectl exec*),Bash(gh pr view*),Bash(gh pr edit*),Bash(gh pr comment*),Read,Write,Glob,Grep'
elif [[ "$PHASE" == "2" ]]; then
  ALLOWED_TOOLS='Bash(git*),Bash(gh pr view*),Bash(gh pr edit*),Bash(gh pr comment*),Edit,Write,Read,Glob,Grep'
else
  echo '{"ts":"'"$(date -u +%FT%TZ)"'","error":"invalid PHASE: '"${PHASE}"'"}' >&2
  exit 1
fi

# Preflight: kubectl must be able to reach the cluster.
if ! kubectl config current-context >/dev/null 2>&1; then
  echo '{"ts":"'"$(date -u +%FT%TZ)"'","error":"kubectl misconfigured","KUBECONFIG":"'"${KUBECONFIG:-unset}"'"}' >&2
  exit 65
fi
if ! kubectl --request-timeout=5s get ns >/dev/null 2>&1; then
  echo '{"ts":"'"$(date -u +%FT%TZ)"'","error":"kubectl cannot reach cluster API"}' >&2
  exit 66
fi

# Workspace directory: configurable via env, defaults to Docker path
WORKSPACE="${WORKSPACE_CLONE_DIR:-/workspace/ecommerce}"

# Phase 2: align local branch to remote before handing control to Claude
if [[ "$PHASE" == "2" ]]; then
  BASE_BRANCH="${BASE_BRANCH:-main}"
  : "${INCIDENT_BRANCH:=incident/${FP_HASH}}"
  export INCIDENT_BRANCH

  git -C "$WORKSPACE" fetch origin --prune
  if git -C "$WORKSPACE" show-ref --verify --quiet "refs/remotes/origin/${INCIDENT_BRANCH}"; then
    git -C "$WORKSPACE" checkout "$INCIDENT_BRANCH" 2>/dev/null || \
      git -C "$WORKSPACE" checkout -b "$INCIDENT_BRANCH" "origin/${INCIDENT_BRANCH}"
    git -C "$WORKSPACE" reset --hard "origin/${INCIDENT_BRANCH}"
  else
    git -C "$WORKSPACE" checkout -B "$INCIDENT_BRANCH" "origin/${BASE_BRANCH}"
  fi
fi

# Both phases run from the workspace so source code is available
cd "$WORKSPACE"

# Ensure templates and docs directories are in the working tree
TEMPLATES_DIR="${TEMPLATES_DIR:-/templates}"
if [[ -d "$TEMPLATES_DIR" ]]; then
  rm -rf "$WORKSPACE/templates"
  cp -r "$TEMPLATES_DIR" "$WORKSPACE/templates"
fi
mkdir -p "$WORKSPACE/docs/incidents"

# Install workspace CLAUDE.md to orient the model (reduces wasted turns)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/workspace-claude.md" ]]; then
  mkdir -p "$WORKSPACE/.claude"
  cp "$SCRIPT_DIR/workspace-claude.md" "$WORKSPACE/.claude/CLAUDE.md"
elif [[ -f "/workspace-claude.md" ]]; then
  mkdir -p "$WORKSPACE/.claude"
  cp "/workspace-claude.md" "$WORKSPACE/.claude/CLAUDE.md"
fi

exec claude -p "$RENDERED_PROMPT" \
  --allowedTools "$ALLOWED_TOOLS" \
  --output-format stream-json \
  --verbose \
  --model "$MODEL" \
  --max-turns "$MAX_TURNS"
