#!/usr/bin/env bash
#
# Initialize the memory store with the canonical finding.
# Seeds the SQLite backend and verifies the finding file exists.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Seeding memory store..."

# Ensure directories
mkdir -p "$ROOT_DIR/memory-store/incidents"
mkdir -p "$ROOT_DIR/memory-store/embeddings"

# Check canonical finding
CANONICAL="$ROOT_DIR/memory-store/incidents/e2836e74.md"
if [[ -f "$CANONICAL" ]]; then
  echo "  Canonical finding e2836e74.md present"
else
  echo "  ERROR: Canonical finding e2836e74.md not found" >&2
  exit 1
fi

# Initialize SQLite schema (creates table if needed)
python3 -c "
import sys, os
sys.path.insert(0, '${ROOT_DIR}/alert-watcher')
os.environ['MEMORY_INCIDENTS_DIR'] = '${ROOT_DIR}/memory-store/incidents'
os.environ['SQLITE_DB_PATH'] = '${ROOT_DIR}/memory-store/embeddings/findings.db'
from store import SqliteBackend
backend = SqliteBackend()
print('  SQLite schema initialized at', backend._db_path)
"

echo "Memory store ready."
