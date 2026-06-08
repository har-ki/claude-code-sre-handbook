#!/usr/bin/env bash
#
# Seeds the memory store with the canonical TOCTOU finding and builds
# the vector index. Run this before test captures.
#
# Requires: Ollama running with nomic-embed-text model
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMORY_DIR="${SCRIPT_DIR}/memory-store/incidents"
EMBEDDINGS_DIR="${SCRIPT_DIR}/memory-store/embeddings"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

echo "==> Seeding memory store"

# Copy canonical finding
mkdir -p "${MEMORY_DIR}" "${EMBEDDINGS_DIR}"
cp "${SCRIPT_DIR}/test-incidents/canonical-e2836e74.md" "${MEMORY_DIR}/e2836e74.md"
echo "    Copied canonical finding to ${MEMORY_DIR}/e2836e74.md"

# Verify Ollama is running and model is available
echo "==> Checking Ollama (${OLLAMA_URL})"
if ! curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
  echo "ERROR: Ollama not reachable at ${OLLAMA_URL}"
  echo "Start Ollama and ensure nomic-embed-text is pulled:"
  echo "  ollama pull nomic-embed-text"
  exit 1
fi

# Build vector index
echo "==> Building vector index"
python3 -c "
import json, hashlib, time, urllib.request

OLLAMA_URL = '${OLLAMA_URL}'
EMBED_MODEL = 'nomic-embed-text'
MEMORY_DIR = '${MEMORY_DIR}'
INDEX_PATH = '${EMBEDDINGS_DIR}/index.json'

def embed(text):
    payload = json.dumps({'model': EMBED_MODEL, 'input': text}).encode()
    req = urllib.request.Request(
        f'{OLLAMA_URL}/api/embed',
        data=payload,
        headers={'Content-Type': 'application/json'},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())['embeddings'][0]

# Canonical finding
service = 'ecommerce-api'
exception_class = 'StockMismatchError'
fp_hash = 'e2836e74'

with open(f'{MEMORY_DIR}/{fp_hash}.md') as f:
    content = f.read()

desc = f'search_document: {service} {exception_class}. {content[:500]}'
vec = embed(desc)

index = [{
    'fp_hash': fp_hash,
    'service': service,
    'exception_class': exception_class,
    'embedding': vec,
    'timestamp': time.time(),
}]

with open(INDEX_PATH, 'w') as f:
    json.dump(index, f, indent=2)

print(f'    Indexed {fp_hash} ({len(vec)}-dim embedding)')
print(f'    Index saved to {INDEX_PATH}')
"

echo ""
echo "==> Memory store ready"
echo "    Finding:  ${MEMORY_DIR}/e2836e74.md"
echo "    Index:    ${EMBEDDINGS_DIR}/index.json"
echo ""
echo "Test incidents available:"
echo "  Drift:         ecommerce-api|InventoryValidationError (hash: de61efe2)"
echo "  Near-miss:     ecommerce-api|StockMismatchError (hash: e2836e74)"
echo "  No-precedent:  ecommerce-api|PaymentGatewayTimeout (hash: 2c8fc300)"
