#!/usr/bin/env bash
#
# One-command setup for Post 02 — "From Investigation to PR".
# Stands up the demo cluster, pushes the ecommerce app to your GitHub,
# and installs the Skills.
#
# Prerequisites: docker, kind, kubectl, gh (authenticated), claude
# Usage: ./setup-post02.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Step 1: Stand up the cluster ─────────────────────────────────────
echo "==> Setting up demo cluster"
"$SCRIPT_DIR/setup.sh"

# ── Step 2: Push ecommerce app to your GitHub ────────────────────────
echo ""
echo "==> Creating ecommerce-app repo on GitHub"
ECOMMERCE_DIR="$SCRIPT_DIR/ecommerce"
cd "$ECOMMERCE_DIR"

if gh repo view ecommerce-app --json name >/dev/null 2>&1; then
  echo "    ecommerce-app repo already exists, skipping"
else
  git init
  gh repo create ecommerce-app --public --source=. --push
fi
cd "$REPO_ROOT"

# ── Step 3: Install Skills ───────────────────────────────────────────
echo ""
echo "==> Installing Skills to ~/.claude/skills/"
mkdir -p ~/.claude/skills
cp -r "$REPO_ROOT/skills/"* ~/.claude/skills/

# ── Step 4: Scale load generator to trigger the bug ──────────────────
echo ""
echo "==> Scaling load generator to 3 replicas"
kubectl scale deployment/load-generator -n ecommerce --replicas=3

# ── Done ─────────────────────────────────────────────────────────────
cat <<EOF

==> Post 02 ready

    Open Claude Code and paste the three prompts from the post.
    Teardown when done: $SCRIPT_DIR/teardown.sh

EOF
