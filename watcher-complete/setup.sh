#!/usr/bin/env bash
#
# One-command setup for the complete watcher.
#
# Creates the kind cluster, deploys the otel-demo stack, seeds the memory
# store, and validates everything is ready for `docker compose up --build`.
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   ./setup.sh
#
# Prerequisites (installed, not managed by this script):
#   docker, kind, kubectl, ollama, gh (authenticated), node/npm
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="claude-sre-demo"
OTEL_DIR="${REPO_ROOT}/otel-demo"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${GREEN}──── $* ────${NC}"; }

# ── Step 1: Check prerequisites ─────────────────────────────────────
step "Checking prerequisites"

command -v docker  >/dev/null || fail "docker not found"
command -v kind    >/dev/null || fail "kind not found"
command -v kubectl >/dev/null || fail "kubectl not found"
command -v ollama  >/dev/null || fail "ollama not found (brew install ollama)"
command -v gh      >/dev/null || fail "gh not found (brew install gh)"
info "CLI tools present"

docker info >/dev/null 2>&1 || fail "Docker daemon not running"
info "Docker daemon running"

[[ -n "${ANTHROPIC_API_KEY:-}" ]] || fail "ANTHROPIC_API_KEY not set. Export it before running this script."
info "ANTHROPIC_API_KEY set"

gh auth status >/dev/null 2>&1 || gh auth token >/dev/null 2>&1 || fail "gh not authenticated. Run: gh auth login"
GH_TOKEN=$(gh auth token 2>/dev/null)
export GH_TOKEN
info "GitHub authenticated ($(gh api user -q .login 2>/dev/null || echo 'unknown'))"

# ── Step 2: Detect GitHub repo ───────────────────────────────────────
step "Detecting GitHub repo"

GITHUB_REPO=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
  | sed -E 's|.*github\.com[:/]||; s|\.git$||')

if [[ -z "$GITHUB_REPO" ]]; then
  fail "Could not detect GitHub repo from git remote. Are you in a clone?"
fi
info "GitHub repo: ${GITHUB_REPO}"

# Update config.yaml if it points to a different repo
CURRENT_REPO=$(grep 'repo:' "$SCRIPT_DIR/alert-watcher/config.yaml" | awk '{print $2}')
if [[ "$CURRENT_REPO" != "$GITHUB_REPO" ]]; then
  sed -i.bak "s|repo: .*|repo: ${GITHUB_REPO}|" "$SCRIPT_DIR/alert-watcher/config.yaml"
  rm -f "$SCRIPT_DIR/alert-watcher/config.yaml.bak"
  info "Updated config.yaml repo: ${CURRENT_REPO} → ${GITHUB_REPO}"
else
  info "config.yaml repo already correct"
fi

# ── Step 3: Kind cluster ─────────────────────────────────────────────
step "Setting up kind cluster"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Cluster ${CLUSTER_NAME} already exists"
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true
else
  info "Creating cluster ${CLUSTER_NAME}..."
  kind create cluster --name "$CLUSTER_NAME" --config "$OTEL_DIR/kind-config.yaml"
  info "Cluster created"
fi

kubectl --request-timeout=10s get ns >/dev/null 2>&1 || fail "Cannot reach cluster API"
info "Cluster reachable"

# ── Step 4: Build and load ecommerce image ───────────────────────────
step "Building ecommerce-api image"

docker build -t ecommerce-api:latest "$OTEL_DIR/ecommerce/backend" -q
kind load docker-image ecommerce-api:latest --name "$CLUSTER_NAME"
info "ecommerce-api image built and loaded into kind"

# ── Step 5: Deploy otel-demo stack ───────────────────────────────────
step "Deploying otel-demo stack"

kubectl apply -f "$OTEL_DIR/k8s/namespace.yaml"
kubectl apply -f "$OTEL_DIR/k8s/clickhouse.yaml"
kubectl apply -f "$OTEL_DIR/k8s/otel-bridge.yaml"
kubectl apply -f "$OTEL_DIR/k8s/ecommerce.yaml"

# Ensure ecommerce-api uses canonical inventory.js (not nearmiss-loader)
# The Dockerfile's CMD already runs server.js → inventory.js.
# Remove any leftover command override that might use the nearmiss variant.
CURRENT_CMD=$(kubectl get deployment ecommerce-api -n ecommerce -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null || echo "")
if [[ "$CURRENT_CMD" == *"nearmiss"* ]]; then
  kubectl patch deployment ecommerce-api -n ecommerce --type='json' \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]'
  info "Removed nearmiss-loader command override"
fi

info "Manifests applied"

# ── Step 6: Wait for pods ────────────────────────────────────────────
step "Waiting for pods"

echo -n "  ClickHouse: "
kubectl rollout status deployment/clickhouse -n clickhouse --timeout=120s 2>&1 | tail -1

echo -n "  OTel bridge: "
kubectl rollout status deployment/otel-clickhouse-bridge --timeout=120s 2>&1 | tail -1

echo -n "  ecommerce-api: "
kubectl rollout status deployment/ecommerce-api -n ecommerce --timeout=120s 2>&1 | tail -1

echo -n "  load-generator: "
kubectl rollout status deployment/load-generator -n ecommerce --timeout=120s 2>&1 | tail -1

info "All pods running"

# ── Step 7: Wait for errors to flow ─────────────────────────────────
step "Waiting for StockMismatchError to appear in ClickHouse"

MAX_WAIT=120
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  COUNT=$(kubectl get --raw "/api/v1/namespaces/clickhouse/services/clickhouse:8123/proxy/?query=SELECT%20count()%20FROM%20otel_logs%20WHERE%20LogAttributes%5B%27exception.type%27%5D%3D%27StockMismatchError%27%20AND%20Timestamp%3E%3Dnow()-INTERVAL%202%20MINUTE" 2>/dev/null || echo "0")
  if [[ "$COUNT" -gt 0 ]]; then
    info "StockMismatchError firing (${COUNT} in last 2 min)"
    break
  fi
  echo -n "."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  warn "StockMismatchError not yet visible after ${MAX_WAIT}s. The load generator may need more time."
  warn "Check: kubectl get --raw '/api/v1/namespaces/clickhouse/services/clickhouse:8123/proxy/?query=SELECT%20count()%20FROM%20otel_logs'"
fi

# ── Step 8: Ollama ───────────────────────────────────────────────────
step "Checking Ollama"

if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  info "Ollama running"
else
  fail "Ollama not reachable at localhost:11434. Start it: ollama serve"
fi

if curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json; models=[m['name'] for m in json.load(sys.stdin)['models']]; sys.exit(0 if any('nomic-embed-text' in m for m in models) else 1)" 2>/dev/null; then
  info "nomic-embed-text model present"
else
  info "Pulling nomic-embed-text..."
  ollama pull nomic-embed-text
  info "nomic-embed-text pulled"
fi

# ── Step 9: Seed memory store ────────────────────────────────────────
step "Seeding memory store"

mkdir -p "$SCRIPT_DIR/memory-store/incidents" "$SCRIPT_DIR/memory-store/embeddings"
mkdir -p "$SCRIPT_DIR/incident-store" "$SCRIPT_DIR/audit-log" "$SCRIPT_DIR/workspace"

export MEMORY_INCIDENTS_DIR="$SCRIPT_DIR/memory-store/incidents"
export SQLITE_DB_PATH="$SCRIPT_DIR/memory-store/embeddings/findings.db"
export OLLAMA_URL="http://localhost:11434"

python3 -c "
import sys, os
sys.path.insert(0, '${SCRIPT_DIR}/alert-watcher')
from store import SqliteBackend

backend = SqliteBackend()

finding_path = os.path.join(os.environ['MEMORY_INCIDENTS_DIR'], 'e2836e74.md')
if os.path.isfile(finding_path):
    with open(finding_path) as f:
        text = f.read().strip()
    ok = backend.persist('e2836e74', 'ecommerce-api', 'StockMismatchError', text)
    if ok:
        print('  Canonical finding e2836e74 seeded with embedding')
    else:
        print('  WARNING: Embedding failed (Ollama issue?) — seeded without embedding')
        import sqlite3, struct, time
        dummy = [0.0] * 768
        blob = struct.pack(f'<{len(dummy)}f', *dummy)
        conn = sqlite3.connect(os.environ['SQLITE_DB_PATH'])
        conn.execute('''INSERT OR REPLACE INTO findings
            (fp_hash, service, exception_class, finding_text, embedding, timestamp, outcome)
            VALUES (?, ?, ?, ?, ?, ?, 'pending')''',
            ('e2836e74', 'ecommerce-api', 'StockMismatchError', text, blob, time.time()))
        conn.commit()
        conn.close()
        print('  Fallback: seeded with dummy embedding')
else:
    print('  ERROR: e2836e74.md not found')
    sys.exit(1)
"

info "Memory store ready"

# ── Step 10: Build watcher images ────────────────────────────────────
step "Building watcher Docker images"

cd "$SCRIPT_DIR"
docker compose build --quiet
info "Images built"

# ── Done ─────────────────────────────────────────────────────────────
step "Setup complete"

echo ""
echo "To start the watcher:"
echo ""
echo "  cd $(basename "$SCRIPT_DIR")"
echo "  export ANTHROPIC_API_KEY=\$ANTHROPIC_API_KEY"
echo "  export GH_TOKEN=\$(gh auth token)"
echo "  docker compose up"
echo ""
echo "The watcher will poll ClickHouse for elevated error rates."
echo "When it detects StockMismatchError, it will:"
echo "  1. Open a draft PR with investigation findings"
echo "  2. Propose a fix and save the finding to memory"
echo ""
echo "After you merge (or close) the PR, run the learning phase:"
echo ""
echo "  FP_HASH=e2836e74 FINGERPRINT='ecommerce-api|StockMismatchError' \\"
echo "  PR_NUM=<pr_number> GITHUB_REPO=${GITHUB_REPO} OUTCOME=merged \\"
echo "  ./scripts/invoke-learn.sh"
echo ""
