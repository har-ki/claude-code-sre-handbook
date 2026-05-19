#!/usr/bin/env python3
"""
Alert watcher — polls ClickHouse for elevated error rates, deduplicates
against open GitHub PRs, opens a draft PR, then triggers claude-runner
for Phase 1 (investigate) and Phase 2 (propose fix).
"""

import hashlib
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

import yaml
from clickhouse_driver import Client

# ── Defaults (overridden by config.yaml) ──────────────────────────────
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

# TODO(v2): watcher webhook receiver — listen for PR-closed events from
# scripts/ecommerce-action.yml and update memory-store accordingly.

# ── Logging ───────────────────────────────────────────────────────────
logging.basicConfig(
    stream=sys.stdout,
    format="%(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("alert-watcher")


def log(msg: str, **kwargs):
    record = {"ts": datetime.now(timezone.utc).isoformat(), "msg": msg, **kwargs}
    logger.info(json.dumps(record))


# ── Config ────────────────────────────────────────────────────────────
def load_config(path: str = "/app/config.yaml") -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


# ── ClickHouse ────────────────────────────────────────────────────────
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


# ── Fingerprinting ────────────────────────────────────────────────────
def fingerprint(service: str, top_error_class: str) -> tuple[str, str]:
    fp = f"{service}|{top_error_class}"
    fp_hash = hashlib.sha256(fp.encode()).hexdigest()[:8]
    return fp, fp_hash


# ── Dedup ─────────────────────────────────────────────────────────────
def check_dedup(repo: str, fp_hash: str) -> str | None:
    """Returns the PR number if an open PR with this fingerprint exists, else None."""
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


# ── Branch naming ─────────────────────────────────────────────────────
def unique_branch_name(fp: str) -> str:
    """Generate incident/<fp> branch, appending -2, -3, etc. if it exists."""
    base = f"incident/{fp}"
    branch = base
    suffix = 1
    while True:
        # Check local
        local = subprocess.run(
            ["git", "-C", WORKSPACE_DIR, "rev-parse", "--verify", f"refs/heads/{branch}"],
            capture_output=True,
        )
        # Check remote
        remote = subprocess.run(
            ["git", "-C", WORKSPACE_DIR, "ls-remote", "--heads", "origin", branch],
            capture_output=True, text=True,
        )
        if local.returncode != 0 and not remote.stdout.strip():
            return branch
        suffix += 1
        branch = f"{base}-{suffix}"


# ── Draft PR ──────────────────────────────────────────────────────────
def open_draft_pr(repo: str, base_branch: str, branch: str, service: str,
                  rate_pct: str, fp_hash: str, trigger_stats: dict) -> str:
    """Create the branch in the workspace clone, push it, open a draft PR. Returns PR number."""
    git = ["git", "-C", WORKSPACE_DIR]
    subprocess.run(git + ["fetch", "origin", "--prune"], check=True)
    subprocess.run(git + ["checkout", "-f", f"origin/{base_branch}"], check=True)
    subprocess.run(git + ["clean", "-fd"], check=True)
    subprocess.run(git + ["checkout", "-B", branch, f"origin/{base_branch}"], check=True)
    subprocess.run(git + ["commit", "--allow-empty", "-m",
                    f"incident: {service} elevated error rate ({rate_pct}%)"], check=True)
    subprocess.run(git + ["push", "-u", "origin", branch, "--force"], check=True)

    title = f"[INVESTIGATING] {service} elevated error rate ({trigger_stats['trigger_rate_pct']}%)"

    # Read PR body template — resolve from TEMPLATES_DIR (container) or relative path (host)
    templates_dir = os.environ.get("TEMPLATES_DIR", "/templates")
    body_path = os.path.join(templates_dir, "pr-body-initial.md")
    if not os.path.exists(body_path):
        # Fallback: resolve relative to this script
        body_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "..", "templates", "pr-body-initial.md")
    body_template = open(body_path).read()
    # Substitute trigger stats into the template
    body = body_template.replace("${TRIGGER_TS}", trigger_stats.get("trigger_ts", ""))
    body = body.replace("${TRIGGER_WINDOW_MINUTES}", str(trigger_stats.get("trigger_window_minutes", "")))
    body = body.replace("${TRIGGER_RATE_PCT}", trigger_stats.get("trigger_rate_pct", ""))
    body = body.replace("${TRIGGER_SAMPLE_COUNT}", str(trigger_stats.get("trigger_sample_count", "")))
    body = body.replace("${THRESHOLD_PCT}", str(int(THRESHOLD * 100)))

    # Ensure the fingerprint label exists (created on demand)
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
    # gh pr create prints the PR URL; extract the number
    pr_url = result.stdout.strip()
    pr_num = pr_url.rstrip("/").split("/")[-1]
    log("draft PR opened", pr_url=pr_url, pr_num=pr_num)
    return pr_num


# ── Claude runner ─────────────────────────────────────────────────────
def run_phase(phase: int, fp: str, fp_hash: str, service: str,
              rate_pct: str, pr_num: str, repo: str,
              model: str, root_cause: str = "", evidence: str = "",
              detection: str = "", trigger_stats: dict | None = None) -> tuple[int, float]:
    """Shell out to claude-runner/invoke.sh. Returns (exit_code, duration_sec)."""
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
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
    }
    if trigger_stats:
        env["TRIGGER_RATE_PCT"] = str(trigger_stats.get("trigger_rate_pct", ""))
        env["TRIGGER_SAMPLE_COUNT"] = str(trigger_stats.get("trigger_sample_count", ""))
        env["TRIGGER_WINDOW_MINUTES"] = str(trigger_stats.get("trigger_window_minutes", ""))
        env["TRIGGER_TS"] = str(trigger_stats.get("trigger_ts", ""))

    audit_path = f"/audit-log/incident-{fp_hash}-phase{phase}.jsonl"
    start = time.monotonic()

    # Build docker run command for the claude-runner image
    runner_image = os.environ.get("RUNNER_IMAGE", "watcher-example-claude-runner")
    workspace_host = os.environ.get("WORKSPACE_HOST_DIR", os.path.abspath("/workspace"))
    audit_host = os.environ.get("AUDIT_LOG_HOST_DIR", os.path.abspath("/audit-log"))
    prompts_host = os.environ.get("PROMPTS_HOST_DIR", os.path.abspath("/prompts"))
    templates_host = os.environ.get("TEMPLATES_HOST_DIR", os.path.abspath("/templates"))
    kubeconfig_host = os.environ.get("KUBECONFIG_HOST", "")

    docker_cmd = [
        "docker", "run", "--rm",
        "--network", "host",
        "-v", f"{workspace_host}:/workspace",
        "-v", f"{audit_host}:/audit-log",
        "-v", f"{prompts_host}:/prompts:ro",
        "-v", f"{templates_host}:/templates:ro",
    ]
    if kubeconfig_host:
        docker_cmd += ["-v", f"{kubeconfig_host}:/home/runner/.kube/config:ro"]
    # Pass env vars
    skip_env = {"PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "HOSTNAME",
                "WORKSPACE_HOST_DIR", "AUDIT_LOG_HOST_DIR", "PROMPTS_HOST_DIR",
                "TEMPLATES_HOST_DIR", "KUBECONFIG_HOST", "RUNNER_IMAGE"}
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

    # Claude exits 0 on max-turns — check the audit log for incomplete runs
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
                                exit_code = 3  # Synthetic failure: ran out of turns
                            break
                    except (json.JSONDecodeError, KeyError):
                        continue
        except OSError:
            pass

    log(f"phase {phase} complete", exit_code=exit_code, duration_sec=round(duration, 1),
        audit_path=audit_path)

    if exit_code != 0:
        # Don't remove investigating label — leave it so retries can pick up
        subprocess.run(
            ["gh", "pr", "edit", pr_num, "--repo", repo,
             "--add-label", "incident:investigating-failed"],
            check=False,
        )
        error_detail = {
            2: "rebase conflict — re-trigger phase 1",
            3: f"ran out of turns ({turns_used} used, max_turns too low) — raise max_turns in config.yaml",
            65: "kubectl misconfigured — check KUBECONFIG mount",
            66: "kubectl cannot reach cluster API — check network/cluster health",
        }.get(exit_code, "")
        detail_line = f"\n\n**Detail:** {error_detail}" if error_detail else ""
        subprocess.run(
            ["gh", "pr", "comment", pr_num, "--repo", repo,
             "--body", f"**Phase {phase} failed** (exit code {exit_code}).{detail_line}\n\nAudit log: `{audit_path}`"],
            check=False,
        )

    return exit_code, duration


# ── Parse Phase 1 PR body ─────────────────────────────────────────────
def parse_phase1_pr_body(repo: str, pr_num: str) -> tuple[str, float]:
    """Extract root_cause and confidence from the Investigation section of a PR body."""
    result = subprocess.run(
        ["gh", "pr", "view", pr_num, "--repo", repo, "--json", "body", "-q", ".body"],
        capture_output=True, text=True,
    )
    body = result.stdout.strip()
    if not body:
        return "", 0.0

    root_cause = ""
    confidence = 0.0

    # Extract root cause from the Summary subsection (first bold line or first paragraph)
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
                # Strip leading bold markers for a clean one-liner
                root_cause = stripped.lstrip("*").rstrip("*").strip()

    # Extract confidence from the Confidence subsection
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


# ── Memory store ──────────────────────────────────────────────────────
def append_incident_record(fp: str, fp_hash: str, pr_url: str,
                           date_str: str, root_cause: str, confidence: float,
                           phase_durations: dict):
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "fingerprint": fp,
        "fp_hash": fp_hash,
        "pr_url": pr_url,
        "incident_report_path": f"docs/incidents/{date_str}-{fp_hash}.md",
        "root_cause": root_cause,
        "confidence": confidence,
        "phase_durations_sec": phase_durations,
    }
    with open("/memory-store/incidents.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")
    log("incident record saved", fp_hash=fp_hash)


# ── Workspace clone ───────────────────────────────────────────────────
WORKSPACE_DIR = os.environ.get("WORKSPACE_CLONE_DIR", "/workspace/ecommerce")


def ensure_workspace_clone(repo: str):
    """Ensure the shared workspace volume has a fresh clone of the fork."""
    if os.path.isdir(os.path.join(WORKSPACE_DIR, ".git")):
        # Already cloned — just fetch
        subprocess.run(["git", "-C", WORKSPACE_DIR, "fetch", "origin", "--prune"],
                       check=False)
        return
    os.makedirs(WORKSPACE_DIR, exist_ok=True)
    subprocess.run(
        ["git", "clone", f"https://github.com/{repo}.git", WORKSPACE_DIR],
        check=True,
    )
    log("workspace cloned", path=WORKSPACE_DIR)


# ── Main loop ─────────────────────────────────────────────────────────
def main():
    global THRESHOLD, MIN_VOLUME, POLL_INTERVAL, DEDUP_WINDOW, MAX_TURNS

    config_path = os.environ.get("CONFIG_PATH", "/app/config.yaml")
    cfg = load_config(config_path)
    repo = cfg["github"]["repo"]
    base_branch = cfg["github"]["base_branch"]
    model = cfg.get("model", "claude-sonnet-4-6")

    # Load tuning knobs from config (fall back to defaults)
    THRESHOLD = cfg.get("threshold", THRESHOLD)
    MIN_VOLUME = cfg.get("min_volume", MIN_VOLUME)
    POLL_INTERVAL = cfg.get("poll_interval_seconds", POLL_INTERVAL)
    DEDUP_WINDOW = cfg.get("dedup_window_seconds", DEDUP_WINDOW)
    MAX_TURNS = cfg.get("max_turns", MAX_TURNS)

    ensure_workspace_clone(repo)
    log("watcher started", repo=repo, poll_interval=POLL_INTERVAL,
        threshold=THRESHOLD, max_turns=MAX_TURNS, model=model)

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

                # Capture trigger stats at the moment the threshold trips
                trigger_stats = {
                    "trigger_window_minutes": cfg.get("lookback_window_minutes", 5),
                    "trigger_rate_pct": rate_pct,
                    "trigger_sample_count": total,
                    "trigger_ts": datetime.now(timezone.utc).isoformat(),
                }

                # Dedup check
                existing_pr = check_dedup(repo, fp_hash)
                if existing_pr:
                    log("dedup hit, commenting on existing PR", pr_num=existing_pr)
                    comment_on_existing_pr(repo, existing_pr, service, error_rate, total)
                    continue

                # Open draft PR
                branch = unique_branch_name(fp_hash)
                pr_num = open_draft_pr(repo, base_branch, branch, service, rate_pct, fp_hash,
                                       trigger_stats=trigger_stats)
                date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

                # Phase 1: investigate — pass trigger stats as env vars
                exit_code_1, dur_1 = run_phase(
                    phase=1, fp=fp, fp_hash=fp_hash, service=service,
                    rate_pct=rate_pct, pr_num=pr_num, repo=repo, model=model,
                    trigger_stats=trigger_stats,
                )
                if exit_code_1 != 0:
                    log("phase 1 failed, skipping phase 2", fp_hash=fp_hash)
                    continue

                # Extract root cause and confidence from the PR body Phase 1 wrote
                root_cause, confidence = parse_phase1_pr_body(repo, pr_num)
                log("parsed phase 1 findings", fp_hash=fp_hash,
                    root_cause=root_cause[:120], confidence=confidence)

                # Phase 2: propose fix
                exit_code_2, dur_2 = run_phase(
                    phase=2, fp=fp, fp_hash=fp_hash, service=service,
                    rate_pct=rate_pct, pr_num=pr_num, repo=repo, model=model,
                    root_cause=root_cause,
                )
                if exit_code_2 != 0:
                    log("phase 2 failed", fp_hash=fp_hash)
                    continue

                # Flip label
                subprocess.run(
                    ["gh", "pr", "edit", pr_num, "--repo", repo,
                     "--remove-label", "incident:investigating",
                     "--add-label", "incident:fix-proposed"],
                    check=False,
                )

                # Record to memory store
                pr_url = f"https://github.com/{repo}/pull/{pr_num}"
                append_incident_record(
                    fp=fp, fp_hash=fp_hash, pr_url=pr_url,
                    date_str=date_str, root_cause=root_cause, confidence=confidence,
                    phase_durations={"phase1": round(dur_1, 1), "phase2": round(dur_2, 1)},
                )

        except Exception:
            log("poll cycle error", error=str(sys.exc_info()[1]))

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
