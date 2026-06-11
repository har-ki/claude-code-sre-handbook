#!/usr/bin/env bash
#
# Verifies the retrieval layer against all three test incidents
# in both modes (exact and similarity). Does NOT run Claude phases —
# just tests that retrieval returns the expected results.
#
# Requires: memory seeded (run seed-memory.sh first), Ollama running
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

echo "================================================================"
echo "Retrieval Verification — $(date -u +%FT%TZ)"
echo "================================================================"
echo "Embedding model: nomic-embed-text (via Ollama at ${OLLAMA_URL})"
echo ""

# Set up Python path so semantic_memory imports work
export PYTHONPATH="${SCRIPT_DIR}/alert-watcher"

python3 -c "
import os, json, sys
sys.path.insert(0, '${SCRIPT_DIR}/alert-watcher')

# Override paths for local testing (not inside Docker)
import semantic_memory
semantic_memory.MEMORY_INCIDENTS_DIR = '${SCRIPT_DIR}/memory-store/incidents'
semantic_memory.EMBEDDINGS_DIR = '${SCRIPT_DIR}/memory-store/embeddings'
semantic_memory.VECTOR_INDEX_PATH = os.path.join(semantic_memory.EMBEDDINGS_DIR, 'index.json')
semantic_memory.OLLAMA_URL = '${OLLAMA_URL}'

from semantic_memory import retrieve, fingerprint

THRESHOLD = 0.75

tests = [
    {
        'name': 'Canonical (same incident)',
        'service': 'ecommerce-api',
        'exception': 'StockMismatchError',
        'expect_exact': True,
        'expect_similar': True,
    },
    {
        'name': 'Drift (renamed exception)',
        'service': 'ecommerce-api',
        'exception': 'InventoryValidationError',
        'expect_exact': False,
        'expect_similar': True,
    },
    {
        'name': 'Near-miss (same hash, different cause)',
        'service': 'ecommerce-api',
        'exception': 'StockMismatchError',
        'expect_exact': True,
        'expect_similar': True,
    },
    {
        'name': 'No-precedent (payment timeout)',
        'service': 'ecommerce-api',
        'exception': 'PaymentGatewayTimeout',
        'expect_exact': False,
        'expect_similar': False,
    },
]

print(f'Threshold: {THRESHOLD}')
print()

all_pass = True
for t in tests:
    fp, fp_hash = fingerprint(t['service'], t['exception'])
    print(f'--- {t[\"name\"]} ---')
    print(f'  Fingerprint: {fp} -> {fp_hash}')

    # Exact mode
    r_exact = retrieve(t['service'], t['exception'], fp_hash, mode='exact', threshold=THRESHOLD)
    exact_ok = r_exact['hit'] == t['expect_exact']
    print(f'  Exact:      hit={r_exact[\"hit\"]} score={r_exact[\"score\"]} matched={r_exact[\"matched_hash\"]}  {\"PASS\" if exact_ok else \"FAIL\"} (expected hit={t[\"expect_exact\"]})')

    # Similarity mode
    r_sim = retrieve(t['service'], t['exception'], fp_hash, mode='similarity', threshold=THRESHOLD)
    sim_ok = r_sim['hit'] == t['expect_similar']
    print(f'  Similarity: hit={r_sim[\"hit\"]} score={r_sim[\"score\"]} matched={r_sim[\"matched_hash\"]}  {\"PASS\" if sim_ok else \"FAIL\"} (expected hit={t[\"expect_similar\"]})')

    if not exact_ok or not sim_ok:
        all_pass = False
    print()

print('================================================================')
print(f'Overall: {\"ALL PASSED\" if all_pass else \"SOME FAILED\"}'  )
print('================================================================')
sys.exit(0 if all_pass else 1)
"
