#!/usr/bin/env bash
#
# Tears down everything setup.sh created.
#
# Usage:
#   ./teardown.sh           # stop watcher + delete cluster
#   ./teardown.sh --keep-cluster  # stop watcher, keep cluster for other use
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER_NAME="claude-sre-demo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
step()  { echo -e "\n${GREEN}──── $* ────${NC}"; }

KEEP_CLUSTER=false
if [[ "${1:-}" == "--keep-cluster" ]]; then
  KEEP_CLUSTER=true
fi

# ── Stop watcher containers ─────────────────────────────────────────
step "Stopping watcher"

cd "$SCRIPT_DIR"
if docker compose ps --quiet 2>/dev/null | grep -q .; then
  docker compose down
  info "Watcher containers stopped"
else
  info "No watcher containers running"
fi

# ── Close any open incident PRs ─────────────────────────────────────
step "Cleaning up incident PRs"

GITHUB_REPO=$(git -C "$(dirname "$SCRIPT_DIR")" remote get-url origin 2>/dev/null \
  | sed -E 's|.*github\.com[:/]||; s|\.git$||')

if [[ -n "$GITHUB_REPO" ]]; then
  OPEN_PRS=$(gh pr list --repo "$GITHUB_REPO" --search "label:incident-fp: state:open" --json number -q '.[].number' 2>/dev/null || echo "")
  if [[ -n "$OPEN_PRS" ]]; then
    for pr in $OPEN_PRS; do
      gh pr close "$pr" --repo "$GITHUB_REPO" --delete-branch 2>/dev/null || true
      info "Closed PR #${pr}"
    done
  else
    info "No open incident PRs"
  fi
fi

# ── Clean up local artifacts ─────────────────────────────────────────
step "Cleaning local artifacts"

rm -rf "$SCRIPT_DIR/workspace/ecommerce"
rm -rf "$SCRIPT_DIR/incident-store"/*
rm -rf "$SCRIPT_DIR/audit-log"/*
rm -f "$SCRIPT_DIR/memory-store/embeddings/findings.db"
info "Workspace, incident store, audit log, and embeddings cleared"
info "Memory store findings (*.md) kept"

# ── Delete kind cluster ──────────────────────────────────────────────
if [[ "$KEEP_CLUSTER" == true ]]; then
  warn "Keeping cluster ${CLUSTER_NAME} (--keep-cluster)"
else
  step "Deleting kind cluster"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "$CLUSTER_NAME"
    info "Cluster ${CLUSTER_NAME} deleted"
  else
    info "Cluster ${CLUSTER_NAME} not found"
  fi
fi

step "Teardown complete"
