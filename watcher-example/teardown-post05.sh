#!/usr/bin/env bash
#
# Teardown for Post 05 — stops the watcher and deletes the kind cluster.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Stopping watcher"
cd "$SCRIPT_DIR"
docker compose down 2>/dev/null || true

echo "==> Deleting kind cluster"
"$REPO_ROOT/otel-demo/teardown.sh"
