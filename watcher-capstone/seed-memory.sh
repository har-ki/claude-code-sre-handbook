#!/usr/bin/env bash
#
# Seeds the memory store with the canonical TOCTOU finding and builds
# the vector index (for whichever backend is configured).
#
# Requires: Ollama running with nomic-embed-text model
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMORY_DIR="${SCRIPT_DIR}/memory-store/incidents"
EMBEDDINGS_DIR="${SCRIPT_DIR}/memory-store/embeddings"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
BACKEND="${STORAGE_BACKEND:-sqlite}"

echo "==> Seeding memory store (backend: ${BACKEND})"

mkdir -p "${MEMORY_DIR}" "${EMBEDDINGS_DIR}"

# Canonical finding should already be at memory-store/incidents/e2836e74.md
if [[ ! -f "${MEMORY_DIR}/e2836e74.md" ]]; then
  echo "ERROR: ${MEMORY_DIR}/e2836e74.md not found"
  exit 1
fi
echo "    Canonical finding present at ${MEMORY_DIR}/e2836e74.md"

# Verify Ollama is running
echo "==> Checking Ollama (${OLLAMA_URL})"
if ! curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
  echo "ERROR: Ollama not reachable at ${OLLAMA_URL}"
  echo "Start Ollama and ensure nomic-embed-text is pulled:"
  echo "  ollama pull nomic-embed-text"
  exit 1
fi

# Build index via store.py
echo "==> Building vector index (backend: ${BACKEND})"
PYTHONPATH="${SCRIPT_DIR}/alert-watcher" \
  MEMORY_INCIDENTS_DIR="${MEMORY_DIR}" \
  EMBEDDINGS_DIR="${EMBEDDINGS_DIR}" \
  SQLITE_DB_PATH="${EMBEDDINGS_DIR}/findings.db" \
  OLLAMA_URL="${OLLAMA_URL}" \
python3 -c "
from store import create_backend
import os

backend = create_backend('${BACKEND}')

fp_hash = 'e2836e74'
service = 'ecommerce-api'
exception_class = 'StockMismatchError'

memory_dir = os.environ['MEMORY_INCIDENTS_DIR']
with open(os.path.join(memory_dir, f'{fp_hash}.md')) as f:
    content = f.read().strip()

ok = backend.persist(fp_hash, service, exception_class, content)
if ok:
    print(f'    Indexed {fp_hash} via {type(backend).__name__}')
else:
    print(f'    ERROR: Failed to index {fp_hash}')
    exit(1)
"

echo ""
echo "==> Memory store ready"
echo "    Finding:  ${MEMORY_DIR}/e2836e74.md"
if [[ "$BACKEND" == "sqlite" ]]; then
  echo "    DB:       ${EMBEDDINGS_DIR}/findings.db"
else
  echo "    Index:    ${EMBEDDINGS_DIR}/index.json"
fi
