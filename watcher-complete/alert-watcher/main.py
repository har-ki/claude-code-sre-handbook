#!/usr/bin/env python3
"""
Alert watcher (complete) — polls ClickHouse for elevated error rates,
deduplicates against open GitHub PRs, opens a draft PR, then triggers
claude-runner for Phase 1 (investigate), Phase 2 (propose fix), and
Phase 3 (learn from merge).

Integrates Part 3 context engineering (retrieval, validation discipline,
correlation, window-edge tuning) with Part 4 learning (outcome-bearing
store, merge-triggered learning phase).

Two-store split:
  - memory-store/  holds per-fingerprint learnings (<sha8>.md + embeddings)
  - incident-store/ holds incidents.jsonl (orchestrator-written metadata)
"""

import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

import yaml
from clickhouse_driver import Client

from store import (
    MEMORY_INCIDENTS_DIR,
    validate_memory_path,
    fingerprint,
    create_backend,
)

# ── Defaults (overridden by config.yaml) ────────────────────────────
THRESHOLD = 0.25
MIN_VOLUME = 100
POLL_INTERVAL = 60
DEDUP_WINDOW = 1800
MAX_TURNS = 40

QUERY = """
SELECT
    ServiceName,
    countIf(SeverityText IN ('ERROR','Error','error')) AS errors,
    count() AS total,
    errors / total AS error_rate,
    topKIf(1)(LogAttributes['exception.type'], LogAttributes['exception.type'] != '')[1] AS top_error_class
FROM otel_logs
WHERE Timestamp >= now() - INTERVAL {lookback} MINUTE
GROUP BY ServiceName
HAVING total >= {min_volume} AND error_rate >= {threshold}
ORDER BY error_rate DESC
LIMIT 5
"""

# ── Incident store ──────────────────────────────────────────────────
INCIDENT_STORE_DIR = "/incident-store"
INCIDENTS_JSONL_PATH = os.path.join(INCIDENT_STORE_DIR, "incidents.jsonl")

# ── Logging ─────────────────────────────────────────────────────────
logging.basicConfig(
    stream=sys.stdout,
    format="%(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("alert-watcher")


def log(msg: str, **kwargs):
    record = {"ts": datetime.now(timezone.utc).isoformat(), "msg": msg, **kwargs}
    logger.info(json.dumps(record))


# ── Config ──────────────────────────────────────────────────────────
def load_config(path: str = "/app/config.yaml") -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


# ── ClickHouse ──────────────────────────────────────────────────────
def poll_clickhouse(cfg: dict) -> list[dict]:
    ch_host = os.environ.get("CLICKHOUSE_HOST", f"{cfg['clickhouse']['host']}:{cfg['clickhouse']['port']}")
    host, _, port = ch_host.partition(":")
    port = int(port) if port else 9000

    client = Client(host=host, port=port)
    query = QUERY.format(
        lookback=cfg.get("lookback_window_minutes", 5),
        min_volume=MIN_VOLUME,
        threshold=THRESHOLD,
    )
    rows = client.execute(query, with_column_types=True)
    columns = [c[0] for c in rows[1]]
    results = []
    for row in rows[0]:
        results.append(dict(zip(columns, row)))
    return results


# ── Dedup ───────────────────────────────────────────────────────────
def check_dedup(repo: str, fp_hash: str) -> str | None:
    result = subprocess.run(
        ["gh", "pr", "list", "--repo", repo, "--search", f"label:incident-fp:{fp_hash} state:open",
         "--json", "number", "--jq", ".[0].number"],
        capture_output=True, text=True,
    )
    pr_num = result.stdout.strip()
    return pr_num if pr_num else None


def comment_on_existing_pr(repo: str, pr_num: str, service: str, error_rate: float, total: int):
    body = (
        f"**Dedup hit** — same fingerprint still firing.\n\n"
        f"- Service: `{service}`\n"
        f"- Error rate: {error_rate:.1%}\n"
        f"- Sample count: {total}\n"
        f"- Time: {datetime.now(timezone.utc).isoformat()}"
    )
    subprocess.run(
        ["gh", "pr", "comment", pr_num, "--repo", repo, "--body", body],
        check=True,
    )


# ── Branch naming ───────────────────────────────────────────────────
def unique_branch_name(fp: str) -> str:
    base = f"incident/{fp}"
    branch = base
    suffix = 1
    while True:
        local = subprocess.run(
            ["git", "-C", WORKSPACE_DIR, "rev-parse", "--verify", f"refs/heads/{branch}"],
            capture_output=True,
        )
        remote = subprocess.run(
            ["git", "-C", WORKSPACE_DIR, "ls-remote", "--heads", "origin", branch],
            capture_output=True, text=True,
        )
        if local.returncode != 0 and not remote.stdout.strip():
            return branch
        suffix += 1
        branch = f"{base}-{suffix}"


# ── Draft PR ────────────────────────────────────────────────────────
def open_draft_pr(repo: str, base_branch: str, branch: str, service: str,
                  rate_pct: str, fp_hash: str, trigger_stats: dict) -> str:
    git = ["git", "-C", WORKSPACE_DIR]
    subprocess.run(git + ["fetch", "origin", "--prune"], check=True)
    subprocess.run(git + ["checkout", "-f", f"origin/{base_branch}"], check=True)
    subprocess.run(git + ["clean", "-fd"], check=True)
    subprocess.run(git + ["checkout", "-B", branch, f"origin/{base_branch}"], check=True)
    subprocess.run(git + ["commit", "--allow-empty", "-m",
                    f"incident: {service} elevated error rate ({rate_pct}%)"], check=True)
    subprocess.run(git + ["push", "-u", "origin", branch, "--force"], check=True)

    title = f"[INVESTIGATING] {service} elevated error rate ({trigger_stats['trigger_rate_pct']}%)"

    templates_dir = os.environ.get("TEMPLATES_DIR", "/templates")
    body_path = os.path.join(templates_dir, "pr-body-initial.md")
    if not os.path.exists(body_path):
        body_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "templates", "pr-body-initial.md")
    body_template = open(body_path).read()
    body = body_template.replace("${TRIGGER_TS}", trigger_stats.get("trigger_ts", ""))
    body = body.replace("${TRIGGER_WINDOW_MINUTES}", str(trigger_stats.get("trigger_window_minutes", "")))
    body = body.replace("${TRIGGER_RATE_PCT}", trigger_stats.get("trigger_rate_pct", ""))
    body = body.replace("${TRIGGER_SAMPLE_COUNT}", str(trigger_stats.get("trigger_sample_count", "")))
    body = body.replace("${THRESHOLD_PCT}", str(int(THRESHOLD * 100)))

    fp_label = f"incident-fp:{fp_hash}"
    subprocess.run(
        ["gh", "label", "create", fp_label, "--repo", repo,
         "--color", "fbca04", "--force"],
        capture_output=True,
    )

    result = subprocess.run(
        ["gh", "pr", "create", "--repo", repo, "--base", base_branch,
         "--head", branch, "--title", title,
         "--body", body,
         "--label", fp_label,
         "--label", "incident:active",
         "--label", "incident:investigating",
         "--draft"],
        capture_output=True, text=True, check=True,
    )
    pr_url = result.stdout.strip()
    pr_num = pr_url.rstrip("/").split("/")[-1]
    log("draft PR opened", pr_url=pr_url, pr_num=pr_num)
    return pr_num


# ── Memory retrieval (via store.py) ─────────────────────────────────
def read_memory(store, service: str, exception_class: str, fp_hash: str,
                mode: str, threshold: float) -> dict:
    """Retrieve prior finding using configured backend and mode.
    Returns finding content + outcome/verdict/lesson if available."""
    result = store.recall(service, exception_class, fp_hash,
                          mode=mode, threshold=threshold)
    if result["hit"]:
        log("memory hit",
            fp_hash=fp_hash,
            mode=result["mode"],
            score=result["score"],
            matched_hash=result["matched_hash"],
            outcome=result.get("outcome"),
            has_lesson=result.get("lesson") is not None)
    else:
        log("memory miss",
            fp_hash=fp_hash,
            mode=result["mode"],
            score=result["score"],
            matched_hash=result.get("matched_hash", ""))
    return result


# ── Memory write verification ───────────────────────────────────────
def verify_memory_write(fp_hash: str) -> bool:
    path = validate_memory_path(fp_hash)
    if path is None:
        return False
    if os.path.isfile(path):
        with open(path) as f:
            content = f.read().strip()
        log("memory write verified", fp_hash=fp_hash, content_len=len(content),
            preview=content[:200])
        return True
    log("memory write NOT detected", fp_hash=fp_hash)
    return False


# ── Index a finding after write-back (via store.py) ─────────────────
def index_finding(store, fp_hash: str, service: str, exception_class: str) -> bool:
    """Read the finding file and persist its embedding via the storage backend."""
    path = validate_memory_path(fp_hash)
    if path is None or not os.path.isfile(path):
        return False
    with open(path) as f:
        content = f.read().strip()
    ok = store.persist(fp_hash, service, exception_class, content)
    if ok:
        log("finding indexed", fp_hash=fp_hash)
    else:
        log("finding indexing failed", fp_hash=fp_hash)
    return ok


# ── Claude runner ───────────────────────────────────────────────────
def run_phase(phase: int, fp: str, fp_hash: str, service: str,
              rate_pct: str, pr_num: str, repo: str,
              model: str, branch: str = "", root_cause: str = "",
              evidence: str = "", detection: str = "",
              trigger_stats: dict | None = None,
              prior_finding: str | None = None,
              retrieval_info: dict | None = None,
              original_finding: str | None = None,
              merged_diff: str | None = None,
              outcome: str | None = None) -> tuple[int, float]:
    """Shell out to claude-runner/invoke.sh. Returns (exit_code, duration_sec)."""
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    retrieval_context = ""
    if retrieval_info:
        retrieval_context = json.dumps({
            "mode": retrieval_info.get("mode", ""),
            "score": retrieval_info.get("score", 0),
            "matched_hash": retrieval_info.get("matched_hash", ""),
            "hit": retrieval_info.get("hit", False),
        })

    env = {
        **os.environ,
        "PHASE": str(phase),
        "FP": fp,
        "FP_HASH": fp_hash,
        "FINGERPRINT": fp,
        "SERVICE": service,
        "RATE_PCT": rate_pct,
        "PR_NUM": pr_num,
        "GITHUB_REPO": repo,
        "MODEL": model,
        "MAX_TURNS": str(MAX_TURNS),
        "ROOT_CAUSE": root_cause,
        "EVIDENCE": evidence,
        "DETECTION": detection,
        "DATE": date_str,
        "INCIDENT_BRANCH": branch,
        "PRIOR_FINDING": prior_finding or "",
        "RETRIEVAL_INFO": retrieval_context,
        "ORIGINAL_FINDING": original_finding or "",
        "MERGED_DIFF": merged_diff or "",
        "OUTCOME": outcome or "",
    }
    if trigger_stats:
        env["TRIGGER_RATE_PCT"] = str(trigger_stats.get("trigger_rate_pct", ""))
        env["TRIGGER_SAMPLE_COUNT"] = str(trigger_stats.get("trigger_sample_count", ""))
        env["TRIGGER_WINDOW_MINUTES"] = str(trigger_stats.get("trigger_window_minutes", ""))
        env["TRIGGER_TS"] = str(trigger_stats.get("trigger_ts", ""))

    audit_path = f"/audit-log/incident-{fp_hash}-phase{phase}.jsonl"
    start = time.monotonic()

    runner_image = os.environ.get("RUNNER_IMAGE", "watcher-complete-claude-runner")
    workspace_host = os.environ.get("WORKSPACE_HOST_DIR", os.path.abspath("/workspace"))
    audit_host = os.environ.get("AUDIT_LOG_HOST_DIR", os.path.abspath("/audit-log"))
    prompts_host = os.environ.get("PROMPTS_HOST_DIR", os.path.abspath("/prompts"))
    templates_host = os.environ.get("TEMPLATES_HOST_DIR", os.path.abspath("/templates"))
    kubeconfig_host = os.environ.get("KUBECONFIG_HOST", "")
    memory_store_host = os.environ.get("MEMORY_STORE_HOST_DIR", os.path.abspath("/memory-store"))

    docker_cmd = [
        "docker", "run", "--rm",
        "--network", "host",
        "-v", f"{workspace_host}:/workspace",
        "-v", f"{audit_host}:/audit-log",
        "-v", f"{prompts_host}:/prompts:ro",
        "-v", f"{templates_host}:/templates:ro",
        "-v", f"{memory_store_host}:/memory-store",
    ]
    if kubeconfig_host:
        docker_cmd += ["-v", f"{kubeconfig_host}:/root/.kube/config:ro",
                       "-e", "KUBECONFIG=/root/.kube/config"]
    skip_env = {"PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "HOSTNAME",
                "WORKSPACE_HOST_DIR", "AUDIT_LOG_HOST_DIR", "PROMPTS_HOST_DIR",
                "TEMPLATES_HOST_DIR", "KUBECONFIG_HOST", "RUNNER_IMAGE",
                "MEMORY_STORE_HOST_DIR"}
    for k, v in env.items():
        if k in skip_env:
            continue
        docker_cmd += ["-e", f"{k}={v}"]
    docker_cmd.append(runner_image)

    with open(audit_path, "w") as audit_f:
        proc = subprocess.Popen(
            docker_cmd,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        for line in proc.stdout:
            decoded = line.decode("utf-8", errors="replace")
            audit_f.write(decoded)
            audit_f.flush()
        proc.wait()

    duration = time.monotonic() - start
    exit_code = proc.returncode

    turns_used = None
    if exit_code == 0:
        try:
            with open(audit_path) as af:
                for audit_line in af:
                    try:
                        event = json.loads(audit_line.strip())
                        if event.get("type") == "result":
                            turns_used = event.get("num_turns")
                            if event.get("subtype") == "error_max_turns":
                                exit_code = 3
                            break
                    except (json.JSONDecodeError, KeyError):
                        continue
        except OSError:
            pass

    log(f"phase {phase} complete", exit_code=exit_code, duration_sec=round(duration, 1),
        audit_path=audit_path)

    if exit_code != 0:
        subprocess.run(
            ["gh", "pr", "edit", pr_num, "--repo", repo,
             "--add-label", "incident:investigating-failed"],
            check=False,
        )
        error_detail = {
            2: "rebase conflict",
            3: f"ran out of turns ({turns_used} used)",
            65: "kubectl misconfigured",
            66: "kubectl cannot reach cluster API",
        }.get(exit_code, "")
        detail_line = f"\n\n**Detail:** {error_detail}" if error_detail else ""
        subprocess.run(
            ["gh", "pr", "comment", pr_num, "--repo", repo,
             "--body", f"**Phase {phase} failed** (exit code {exit_code}).{detail_line}\n\nAudit log: `{audit_path}`"],
            check=False,
        )

    return exit_code, duration


# ── Parse Phase 1 PR body ──────────────────────────────────────────
def parse_phase1_pr_body(repo: str, pr_num: str) -> tuple[str, float]:
    result = subprocess.run(
        ["gh", "pr", "view", pr_num, "--repo", repo, "--json", "body", "-q", ".body"],
        capture_output=True, text=True,
    )
    body = result.stdout.strip()
    if not body:
        return "", 0.0

    root_cause = ""
    confidence = 0.0

    in_summary = False
    for line in body.splitlines():
        if line.strip().startswith("### Summary"):
            in_summary = True
            continue
        if in_summary:
            stripped = line.strip()
            if stripped.startswith("###") or stripped.startswith("## "):
                break
            if stripped and not root_cause:
                root_cause = stripped.lstrip("*").rstrip("*").strip()

    in_confidence = False
    for line in body.splitlines():
        if line.strip().startswith("### Confidence"):
            in_confidence = True
            continue
        if in_confidence:
            stripped = line.strip().lower()
            if stripped.startswith("###") or stripped.startswith("## "):
                break
            if "high" in stripped:
                confidence = 1.0
                break
            elif "medium" in stripped:
                confidence = 0.5
                break
            elif "low" in stripped:
                confidence = 0.25
                break

    return root_cause, confidence


# ── Incident record (writes to incident-store/) ────────────────────
def append_incident_record(fp: str, fp_hash: str, pr_url: str,
                           date_str: str, root_cause: str, confidence: float,
                           phase_durations: dict, retrieval_result: dict,
                           memory_write_verified: bool):
    """Append incident metadata to incident-store/incidents.jsonl."""
    os.makedirs(INCIDENT_STORE_DIR, exist_ok=True)
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "fingerprint": fp,
        "fp_hash": fp_hash,
        "pr_url": pr_url,
        "incident_report_path": f"docs/incidents/{date_str}-{fp_hash}.md",
        "root_cause": root_cause,
        "confidence": confidence,
        "phase_durations_sec": phase_durations,
        "retrieval": {
            "mode": retrieval_result.get("mode", ""),
            "hit": retrieval_result.get("hit", False),
            "score": retrieval_result.get("score", 0),
            "matched_hash": retrieval_result.get("matched_hash", ""),
            "outcome": retrieval_result.get("outcome"),
            "has_lesson": retrieval_result.get("lesson") is not None,
        },
        "memory_write_verified": memory_write_verified,
    }
    with open(INCIDENTS_JSONL_PATH, "a") as f:
        f.write(json.dumps(record) + "\n")
    log("incident record saved", fp_hash=fp_hash)


# ── Workspace clone ────────────────────────────────────────────────
WORKSPACE_DIR = os.environ.get("WORKSPACE_CLONE_DIR", "/workspace/ecommerce")


def ensure_workspace_clone(repo: str):
    if os.path.isdir(os.path.join(WORKSPACE_DIR, ".git")):
        subprocess.run(["git", "-C", WORKSPACE_DIR, "fetch", "origin", "--prune"],
                       check=False)
        return
    os.makedirs(WORKSPACE_DIR, exist_ok=True)
    token = os.environ.get("GH_TOKEN", "")
    if token:
        clone_url = f"https://x-access-token:{token}@github.com/{repo}.git"
    else:
        clone_url = f"https://github.com/{repo}.git"
    subprocess.run(
        ["git", "clone", clone_url, WORKSPACE_DIR],
        check=True,
    )
    log("workspace cloned", path=WORKSPACE_DIR)


# ── Main loop ──────────────────────────────────────────────────────
def main():
    global THRESHOLD, MIN_VOLUME, POLL_INTERVAL, DEDUP_WINDOW, MAX_TURNS

    config_path = os.environ.get("CONFIG_PATH", "/app/config.yaml")
    cfg = load_config(config_path)
    repo = cfg["github"]["repo"]
    base_branch = cfg["github"]["base_branch"]
    model = cfg.get("model", "claude-sonnet-4-6")

    THRESHOLD = cfg.get("threshold", THRESHOLD)
    MIN_VOLUME = cfg.get("min_volume", MIN_VOLUME)
    POLL_INTERVAL = cfg.get("poll_interval_seconds", POLL_INTERVAL)
    DEDUP_WINDOW = cfg.get("dedup_window_seconds", DEDUP_WINDOW)
    MAX_TURNS = cfg.get("max_turns", MAX_TURNS)

    # Storage backend + retrieval config
    storage_backend = cfg.get("storage_backend", "sqlite")
    retrieval_mode = cfg.get("retrieval_mode", "similarity")
    similarity_threshold = cfg.get("similarity_threshold", 0.75)
    validation_discipline = cfg.get("validation_discipline", True)

    store = create_backend(storage_backend)

    os.makedirs(MEMORY_INCIDENTS_DIR, exist_ok=True)
    os.makedirs(INCIDENT_STORE_DIR, exist_ok=True)

    ensure_workspace_clone(repo)
    log("watcher started (complete)", repo=repo, poll_interval=POLL_INTERVAL,
        threshold=THRESHOLD, max_turns=MAX_TURNS, model=model,
        storage_backend=storage_backend,
        retrieval_mode=retrieval_mode,
        similarity_threshold=similarity_threshold,
        validation_discipline=validation_discipline)

    while True:
        try:
            alerts = poll_clickhouse(cfg)
            if not alerts:
                log("poll complete, no alerts")
            for alert in alerts:
                service = alert["ServiceName"]
                error_rate = float(alert["error_rate"])
                total = int(alert["total"])
                top_error_class = alert.get("top_error_class", "Unknown")
                rate_pct = f"{error_rate * 100:.0f}"

                fp, fp_hash = fingerprint(service, top_error_class)
                log("alert detected", service=service, error_rate=rate_pct,
                    fingerprint=fp, fp_hash=fp_hash)

                trigger_stats = {
                    "trigger_window_minutes": cfg.get("lookback_window_minutes", 5),
                    "trigger_rate_pct": rate_pct,
                    "trigger_sample_count": total,
                    "trigger_ts": datetime.now(timezone.utc).isoformat(),
                }

                existing_pr = check_dedup(repo, fp_hash)
                if existing_pr:
                    log("dedup hit, commenting on existing PR", pr_num=existing_pr)
                    comment_on_existing_pr(repo, existing_pr, service, error_rate, total)
                    continue

                branch = unique_branch_name(fp_hash)
                pr_num = open_draft_pr(repo, base_branch, branch, service, rate_pct, fp_hash,
                                       trigger_stats=trigger_stats)
                date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

                # Memory retrieval (via store.py backend — returns outcome fields)
                retrieval_result = read_memory(
                    store, service, top_error_class, fp_hash,
                    mode=retrieval_mode, threshold=similarity_threshold,
                )
                prior_finding = retrieval_result["content"]

                # Phase 1: investigate
                exit_code_1, dur_1 = run_phase(
                    phase=1, fp=fp, fp_hash=fp_hash, service=service,
                    rate_pct=rate_pct, pr_num=pr_num, repo=repo, model=model,
                    branch=branch, trigger_stats=trigger_stats,
                    prior_finding=prior_finding,
                    retrieval_info=retrieval_result,
                )
                if exit_code_1 != 0:
                    log("phase 1 failed, skipping phase 2", fp_hash=fp_hash)
                    continue

                root_cause, confidence = parse_phase1_pr_body(repo, pr_num)
                log("parsed phase 1 findings", fp_hash=fp_hash,
                    root_cause=root_cause[:120], confidence=confidence)

                # Phase 2: propose fix (includes required memory write)
                exit_code_2, dur_2 = run_phase(
                    phase=2, fp=fp, fp_hash=fp_hash, service=service,
                    rate_pct=rate_pct, pr_num=pr_num, repo=repo, model=model,
                    branch=branch, root_cause=root_cause,
                )
                if exit_code_2 != 0:
                    log("phase 2 failed", fp_hash=fp_hash)
                    continue

                # Verify and index memory write
                memory_write_ok = verify_memory_write(fp_hash)
                if memory_write_ok:
                    index_finding(store, fp_hash, service, top_error_class)

                subprocess.run(
                    ["gh", "pr", "edit", pr_num, "--repo", repo,
                     "--remove-label", "incident:investigating",
                     "--add-label", "incident:fix-proposed"],
                    check=False,
                )

                pr_url = f"https://github.com/{repo}/pull/{pr_num}"
                append_incident_record(
                    fp=fp, fp_hash=fp_hash, pr_url=pr_url,
                    date_str=date_str, root_cause=root_cause, confidence=confidence,
                    phase_durations={"phase1": round(dur_1, 1), "phase2": round(dur_2, 1)},
                    retrieval_result=retrieval_result,
                    memory_write_verified=memory_write_ok,
                )

        except Exception:
            log("poll cycle error", error=str(sys.exc_info()[1]))

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
