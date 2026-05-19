#!/usr/bin/env bash
#
# One-command setup for Post 05 — "On-Demand vs Always-On: Building".
# Stands up the demo cluster, bootstraps the repo for incident PRs,
# configures the watcher, and starts it.
#
# Prerequisites: docker, kind, kubectl, gh (authenticated)
# Usage: ./setup-post05.sh [OWNER/REPO]
#
#   OWNER/REPO defaults to the origin remote of this repo.
#   Set ANTHROPIC_API_KEY and GH_TOKEN in the environment,
#   or create watcher-example/.env before running.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OTEL_DIR="$REPO_ROOT/otel-demo"

REPO="${1:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')}"
if [[ -z "$REPO" ]]; then
  echo "Usage: $0 OWNER/REPO" >&2
  exit 1
fi

# ── Step 1: Stand up the demo cluster ────────────────────────────────
echo "==> Setting up demo cluster"
"$OTEL_DIR/setup.sh"

# ── Step 2: Bootstrap fork (labels, incident structure) ──────────────
echo ""
echo "==> Bootstrapping repo: ${REPO}"
"$SCRIPT_DIR/scripts/bootstrap-fork.sh" "$REPO"

# ── Step 3: Configure .env ───────────────────────────────────────────
echo ""
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  # Fill in from environment if available
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    sed -i.bak "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}|" "$SCRIPT_DIR/.env"
    rm -f "$SCRIPT_DIR/.env.bak"
  fi
  if [[ -z "${GH_TOKEN:-}" ]]; then
    # Reuse the token from gh auth if available
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    sed -i.bak "s|^GH_TOKEN=.*|GH_TOKEN=${GH_TOKEN}|" "$SCRIPT_DIR/.env"
    rm -f "$SCRIPT_DIR/.env.bak"
  fi
  echo "==> Created .env from .env.example"
  # Check if keys are still placeholders
  if grep -q 'sk-ant-\.\.\.' "$SCRIPT_DIR/.env"; then
    echo "    WARNING: ANTHROPIC_API_KEY is still a placeholder — edit $SCRIPT_DIR/.env"
  fi
  if grep -q 'ghp_\.\.\.' "$SCRIPT_DIR/.env"; then
    echo "    WARNING: GH_TOKEN is still a placeholder — edit $SCRIPT_DIR/.env"
  fi
else
  echo "==> .env already exists, skipping"
fi

# ── Step 4: Start the watcher ────────────────────────────────────────
echo ""
echo "==> Starting watcher (docker compose)"
cd "$SCRIPT_DIR"
docker compose up -d --build

# ── Step 5: Scale load generator to trigger the bug ──────────────────
echo ""
echo "==> Scaling load generator to 3 replicas"
kubectl scale deployment/load-generator -n ecommerce --replicas=3

# ── Done ─────────────────────────────────────────────────────────────
cat <<EOF

==> Post 05 ready

    The watcher is polling. Watch it work:
      docker compose logs -f alert-watcher

    Teardown when done:
      $SCRIPT_DIR/teardown-post05.sh

EOF
