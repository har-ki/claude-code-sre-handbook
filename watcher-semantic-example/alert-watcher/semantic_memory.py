"""
Semantic memory layer for the SRE watcher.

Supports two retrieval modes (configurable):
  - exact:      sha256-hash lookup (identical to watcher-memory-example)
  - similarity: embed the incident description, cosine-search stored findings

Embedding is done via Ollama's local nomic-embed-text model.
Vector index is a flat JSON file — sufficient for hundreds of findings.
"""

import hashlib
import json
import math
import os
import re
import time
import urllib.request
import urllib.error

MEMORY_INCIDENTS_DIR = "/memory-store/incidents"
EMBEDDINGS_DIR = "/memory-store/embeddings"
VECTOR_INDEX_PATH = os.path.join(EMBEDDINGS_DIR, "index.json")

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://host.docker.internal:11434")
EMBED_MODEL = "nomic-embed-text"


# ── Path validation ─────────────────────────────────────────────────

def validate_memory_path(fp_hash: str) -> str | None:
    if not re.match(r'^[0-9a-f]{8}$', fp_hash):
        return None
    path = os.path.join(MEMORY_INCIDENTS_DIR, f"{fp_hash}.md")
    resolved = os.path.realpath(path)
    if not resolved.startswith(os.path.realpath(MEMORY_INCIDENTS_DIR) + os.sep):
        return None
    return path


# ── Embedding via Ollama ────────────────────────────────────────────

def embed_text(text: str, retries: int = 2) -> list[float] | None:
    """Call Ollama's /api/embed endpoint. Returns a 768-dim vector or None."""
    payload = json.dumps({"model": EMBED_MODEL, "input": text}).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/embed",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
                return data["embeddings"][0]
        except (urllib.error.URLError, KeyError, json.JSONDecodeError) as e:
            if attempt < retries:
                time.sleep(1)
            else:
                return None
    return None


def cosine_similarity(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


# ── Incident description for embedding ──────────────────────────────

def _expand_exception_context(exception_class: str) -> str:
    """Expand an exception class name into descriptive domain context.
    This gives the embedding model enough semantic signal to differentiate
    structurally similar but semantically distinct incidents."""
    # Split camelCase/PascalCase into words for semantic expansion
    import re
    words = re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', exception_class).lower()
    return f"{exception_class}. Incident type: {words}."


def build_query_text(service: str, exception_class: str,
                     extra_context: str = "") -> str:
    """Build query text for similarity search (prefixed for nomic-embed-text).
    Includes expanded domain context so the model can differentiate
    incidents with different exception classes on the same service."""
    expanded = _expand_exception_context(exception_class)
    text = f"search_query: Service {service} is throwing {expanded}"
    if extra_context:
        text += f" {extra_context}"
    return text


def build_document_text(service: str, exception_class: str,
                        finding_content: str) -> str:
    """Build document text for indexing (prefixed for nomic-embed-text).
    Includes the finding content for rich semantic matching."""
    return (f"search_document: Service {service} {exception_class}. "
            f"{finding_content[:500]}")


# ── Vector index (flat JSON file) ───────────────────────────────────

def load_index() -> list[dict]:
    if os.path.isfile(VECTOR_INDEX_PATH):
        with open(VECTOR_INDEX_PATH) as f:
            return json.load(f)
    return []


def save_index(entries: list[dict]):
    os.makedirs(EMBEDDINGS_DIR, exist_ok=True)
    with open(VECTOR_INDEX_PATH, "w") as f:
        json.dump(entries, f, indent=2)


def add_to_index(fp_hash: str, service: str, exception_class: str,
                 finding_text: str) -> bool:
    """Embed a finding and add/update it in the vector index.
    Uses search_document prefix with finding content for rich semantic matching."""
    desc = build_document_text(service, exception_class, finding_text)
    vec = embed_text(desc)
    if vec is None:
        return False

    index = load_index()
    # Update existing entry or append
    updated = False
    for entry in index:
        if entry["fp_hash"] == fp_hash:
            entry["embedding"] = vec
            entry["service"] = service
            entry["exception_class"] = exception_class
            entry["timestamp"] = time.time()
            updated = True
            break
    if not updated:
        index.append({
            "fp_hash": fp_hash,
            "service": service,
            "exception_class": exception_class,
            "embedding": vec,
            "timestamp": time.time(),
        })
    save_index(index)
    return True


# ── Retrieval ───────────────────────────────────────────────────────

def retrieve_exact(fp_hash: str) -> tuple[str | None, float]:
    """Exact-hash lookup. Returns (content, 1.0) or (None, 0.0)."""
    path = validate_memory_path(fp_hash)
    if path and os.path.isfile(path):
        with open(path) as f:
            return f.read().strip(), 1.0
    return None, 0.0


def retrieve_similar(service: str, exception_class: str,
                     threshold: float = 0.75) -> tuple[str | None, float, str]:
    """
    Similarity search. Returns (content, score, matched_hash) or (None, score, "").
    If top score < threshold, returns no finding (safe silence).
    """
    query_text = build_query_text(service, exception_class)
    query_vec = embed_text(query_text)
    if query_vec is None:
        return None, 0.0, ""

    index = load_index()
    if not index:
        return None, 0.0, ""

    best_score = -1.0
    best_hash = ""
    for entry in index:
        score = cosine_similarity(query_vec, entry["embedding"])
        if score > best_score:
            best_score = score
            best_hash = entry["fp_hash"]

    if best_score < threshold:
        return None, best_score, best_hash

    # Load the finding file for the best match
    path = validate_memory_path(best_hash)
    if path and os.path.isfile(path):
        with open(path) as f:
            return f.read().strip(), best_score, best_hash

    return None, best_score, best_hash


def retrieve(service: str, exception_class: str, fp_hash: str,
             mode: str = "exact", threshold: float = 0.75) -> dict:
    """
    Unified retrieval interface.

    Args:
        mode: "exact" or "similarity"
        threshold: similarity score cutoff (similarity mode only)

    Returns dict with:
        content: str | None
        score: float
        mode: str
        matched_hash: str
        hit: bool
    """
    if mode == "exact":
        content, score = retrieve_exact(fp_hash)
        return {
            "content": content,
            "score": score,
            "mode": "exact",
            "matched_hash": fp_hash if content else "",
            "hit": content is not None,
        }
    elif mode == "similarity":
        content, score, matched_hash = retrieve_similar(
            service, exception_class, threshold
        )
        return {
            "content": content,
            "score": round(score, 4),
            "mode": "similarity",
            "matched_hash": matched_hash,
            "hit": content is not None,
        }
    else:
        raise ValueError(f"Unknown retrieval mode: {mode}")


# ── Fingerprinting (same as watcher-memory-example) ─────────────────

def fingerprint(service: str, top_error_class: str) -> tuple[str, str]:
    fp = f"{service}|{top_error_class}"
    fp_hash = hashlib.sha256(fp.encode()).hexdigest()[:8]
    return fp, fp_hash
