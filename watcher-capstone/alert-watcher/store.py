"""
Storage interface for the SRE watcher capstone.

Provides recall() and persist() across two backends:
  - JsonBackend: flat JSON vector index (ported from semantic_memory.py)
  - SqliteBackend: SQLite with atomic writes, same cosine search in Python

Both backends share embedding (Ollama nomic-embed-text, 768-dim) and
cosine_similarity — the storage layer is what changes, not retrieval math.

Backend selected by config: storage_backend: json | sqlite (default: sqlite).
"""

import hashlib
import json
import math
import os
import re
import sqlite3
import struct
import time
import urllib.request
import urllib.error
from abc import ABC, abstractmethod

MEMORY_INCIDENTS_DIR = os.environ.get(
    "MEMORY_INCIDENTS_DIR", "/memory-store/incidents"
)
EMBEDDINGS_DIR = os.environ.get(
    "EMBEDDINGS_DIR", "/memory-store/embeddings"
)
VECTOR_INDEX_PATH = os.path.join(EMBEDDINGS_DIR, "index.json")
SQLITE_DB_PATH = os.environ.get(
    "SQLITE_DB_PATH", "/memory-store/embeddings/findings.db"
)

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://host.docker.internal:11434")
EMBED_MODEL = "nomic-embed-text"


# ── Path validation ─────────────────────────────────────────────────

def validate_memory_path(fp_hash: str) -> str | None:
    """Validate fp_hash and return safe path within memory-store/incidents/.
    Returns None if the hash is invalid or path escapes the directory."""
    if not re.match(r'^[0-9a-f]{8}$', fp_hash):
        return None
    path = os.path.join(MEMORY_INCIDENTS_DIR, f"{fp_hash}.md")
    resolved = os.path.realpath(path)
    if not resolved.startswith(os.path.realpath(MEMORY_INCIDENTS_DIR) + os.sep):
        return None
    return path


# ── Fingerprinting ──────────────────────────────────────────────────

def fingerprint(service: str, top_error_class: str) -> tuple[str, str]:
    fp = f"{service}|{top_error_class}"
    fp_hash = hashlib.sha256(fp.encode()).hexdigest()[:8]
    return fp, fp_hash


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
        except (urllib.error.URLError, KeyError, json.JSONDecodeError):
            if attempt < retries:
                time.sleep(1)
    return None


def cosine_similarity(a: list[float], b: list[float]) -> float:
    """Cosine similarity between two vectors. Shared by all backends."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


# ── Embedding text builders ─────────────────────────────────────────

def _expand_exception_context(exception_class: str) -> str:
    """Expand CamelCase into words for semantic signal."""
    words = re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', exception_class).lower()
    return f"{exception_class}. Incident type: {words}."


def build_query_text(service: str, exception_class: str,
                     extra_context: str = "") -> str:
    """Build query text for similarity search (nomic-embed-text prefix)."""
    expanded = _expand_exception_context(exception_class)
    text = f"search_query: Service {service} is throwing {expanded}"
    if extra_context:
        text += f" {extra_context}"
    return text


def build_document_text(service: str, exception_class: str,
                        finding_content: str) -> str:
    """Build document text for indexing (nomic-embed-text prefix)."""
    return (f"search_document: Service {service} {exception_class}. "
            f"{finding_content[:500]}")


# ── Blob serialization for SQLite ───────────────────────────────────

def _vec_to_blob(vec: list[float]) -> bytes:
    """Pack a float list into a compact binary blob (little-endian floats)."""
    return struct.pack(f"<{len(vec)}f", *vec)


def _blob_to_vec(blob: bytes) -> list[float]:
    """Unpack a binary blob back to a float list."""
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}f", blob))


# ── Abstract interface ──────────────────────────────────────────────

class StorageBackend(ABC):
    """Abstract storage interface for incident findings."""

    @abstractmethod
    def recall(self, service: str, exception_class: str, fp_hash: str,
               mode: str = "exact", threshold: float = 0.75) -> dict:
        """Retrieve a prior finding.

        Returns dict with:
            content: str | None
            score: float
            mode: str
            matched_hash: str
            hit: bool
        """

    @abstractmethod
    def persist(self, fp_hash: str, service: str, exception_class: str,
                finding_text: str) -> bool:
        """Store a finding and update the embedding index. Returns success."""


# ── JsonBackend (ported from semantic_memory.py) ────────────────────

class JsonBackend(StorageBackend):
    """Flat JSON vector index — verbatim port of watcher-semantic-example logic."""

    def _load_index(self) -> list[dict]:
        if os.path.isfile(VECTOR_INDEX_PATH):
            with open(VECTOR_INDEX_PATH) as f:
                return json.load(f)
        return []

    def _save_index(self, entries: list[dict]):
        os.makedirs(EMBEDDINGS_DIR, exist_ok=True)
        with open(VECTOR_INDEX_PATH, "w") as f:
            json.dump(entries, f, indent=2)

    def _retrieve_exact(self, fp_hash: str) -> tuple[str | None, float]:
        path = validate_memory_path(fp_hash)
        if path and os.path.isfile(path):
            with open(path) as f:
                return f.read().strip(), 1.0
        return None, 0.0

    def _retrieve_similar(self, service: str, exception_class: str,
                          threshold: float) -> tuple[str | None, float, str]:
        query_text = build_query_text(service, exception_class)
        query_vec = embed_text(query_text)
        if query_vec is None:
            return None, 0.0, ""

        index = self._load_index()
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

        path = validate_memory_path(best_hash)
        if path and os.path.isfile(path):
            with open(path) as f:
                return f.read().strip(), best_score, best_hash
        return None, best_score, best_hash

    def recall(self, service: str, exception_class: str, fp_hash: str,
               mode: str = "exact", threshold: float = 0.75) -> dict:
        if mode == "exact":
            content, score = self._retrieve_exact(fp_hash)
            return {
                "content": content,
                "score": score,
                "mode": "exact",
                "matched_hash": fp_hash if content else "",
                "hit": content is not None,
            }
        elif mode == "similarity":
            content, score, matched_hash = self._retrieve_similar(
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

    def persist(self, fp_hash: str, service: str, exception_class: str,
                finding_text: str) -> bool:
        desc = build_document_text(service, exception_class, finding_text)
        vec = embed_text(desc)
        if vec is None:
            return False

        index = self._load_index()
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
        self._save_index(index)
        return True


# ── SqliteBackend (NEW) ─────────────────────────────────────────────

class SqliteBackend(StorageBackend):
    """SQLite-backed storage with atomic writes.

    Schema: findings(fp_hash PK, service, exception_class, finding_text,
                     embedding BLOB, timestamp REAL)

    Cosine search is done in Python after loading candidate rows — SQLite
    provides atomicity and consistency, not vector search. For scale,
    sqlite-vec is the upgrade path (not built here).
    """

    def __init__(self, db_path: str = SQLITE_DB_PATH):
        self._db_path = db_path
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path)

    def _init_schema(self):
        with self._connect() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS findings (
                    fp_hash      TEXT PRIMARY KEY,
                    service      TEXT NOT NULL,
                    exception_class TEXT NOT NULL,
                    finding_text TEXT NOT NULL,
                    embedding    BLOB NOT NULL,
                    timestamp    REAL NOT NULL
                )
            """)

    def _retrieve_exact(self, fp_hash: str) -> tuple[str | None, float]:
        path = validate_memory_path(fp_hash)
        if path and os.path.isfile(path):
            with open(path) as f:
                return f.read().strip(), 1.0
        return None, 0.0

    def _retrieve_similar(self, service: str, exception_class: str,
                          threshold: float) -> tuple[str | None, float, str]:
        query_text = build_query_text(service, exception_class)
        query_vec = embed_text(query_text)
        if query_vec is None:
            return None, 0.0, ""

        with self._connect() as conn:
            rows = conn.execute(
                "SELECT fp_hash, embedding FROM findings"
            ).fetchall()

        if not rows:
            return None, 0.0, ""

        best_score = -1.0
        best_hash = ""
        for row_hash, blob in rows:
            stored_vec = _blob_to_vec(blob)
            score = cosine_similarity(query_vec, stored_vec)
            if score > best_score:
                best_score = score
                best_hash = row_hash

        if best_score < threshold:
            return None, best_score, best_hash

        path = validate_memory_path(best_hash)
        if path and os.path.isfile(path):
            with open(path) as f:
                return f.read().strip(), best_score, best_hash
        return None, best_score, best_hash

    def recall(self, service: str, exception_class: str, fp_hash: str,
               mode: str = "exact", threshold: float = 0.75) -> dict:
        if mode == "exact":
            content, score = self._retrieve_exact(fp_hash)
            return {
                "content": content,
                "score": score,
                "mode": "exact",
                "matched_hash": fp_hash if content else "",
                "hit": content is not None,
            }
        elif mode == "similarity":
            content, score, matched_hash = self._retrieve_similar(
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

    def persist(self, fp_hash: str, service: str, exception_class: str,
                finding_text: str) -> bool:
        desc = build_document_text(service, exception_class, finding_text)
        vec = embed_text(desc)
        if vec is None:
            return False

        blob = _vec_to_blob(vec)
        with self._connect() as conn:
            conn.execute("""
                INSERT INTO findings (fp_hash, service, exception_class,
                                      finding_text, embedding, timestamp)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(fp_hash) DO UPDATE SET
                    service = excluded.service,
                    exception_class = excluded.exception_class,
                    finding_text = excluded.finding_text,
                    embedding = excluded.embedding,
                    timestamp = excluded.timestamp
            """, (fp_hash, service, exception_class, finding_text,
                  blob, time.time()))
        return True


# ── Factory ─────────────────────────────────────────────────────────

def create_backend(backend_type: str = "sqlite") -> StorageBackend:
    """Create a storage backend by config name."""
    if backend_type == "json":
        return JsonBackend()
    elif backend_type == "sqlite":
        return SqliteBackend()
    else:
        raise ValueError(f"Unknown storage backend: {backend_type}")
