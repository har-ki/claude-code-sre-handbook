# Watcher v0.2 — Implementation Report

**Branch:** `phase-4/watcher-v0-2`
**PR:** har-ki/claude-code-sre-handbook#23
**Base:** `drafts/05-watcher`
**Date:** 2026-05-17

---

## What was done

Three bugs surfaced during the PR #19 capture run. All three are now fixed in three separate commits (one per issue, in the prescribed order):

```
a5a079d fix(watcher): ensure kubectl is available inside claude-runner
6f9a026 fix(watcher): capture trigger stats at alert time, show in PR body
bf5364c fix(watcher): resolve Phase 2 git exit 128 with proper branch prep
```

---

## Issue 2 — kubectl unavailable inside the runner

**Root cause:** `kubectl` was installed in the runner image but `KUBECONFIG` env var wasn't set, so it couldn't find the bind-mounted kubeconfig at `/home/runner/.kube/config`.

**Changes:**

| File | Change |
|------|--------|
| `claude-runner/Dockerfile` | Added `ENV KUBECONFIG=/home/runner/.kube/config` |
| `claude-runner/invoke.sh` | Added preflight check: exit 65 if config broken, exit 66 if cluster unreachable |
| `alert-watcher/main.py` | Extended failure-comment logic to post human-readable detail for exit codes 2, 65, 66 |

**Verified:** `docker run --network host --entrypoint "" -v ~/.kube/config:/home/runner/.kube/config:ro watcher-example-claude-runner kubectl get nodes` returns the kind node.

---

## Issue 3 — Threshold trigger and PR body disagreed

**Root cause:** The watcher fired on a 1-minute window crossing 25%, but by the time Phase 1 queried a 15-minute window, the rate had averaged down. The PR showed Phase 1's number, not the trigger's.

**Changes:**

| File | Change |
|------|--------|
| `alert-watcher/main.py` | Captures `trigger_stats` dict (rate, sample count, window, timestamp) at the moment the threshold trips. Passes as env vars to the runner. PR title now uses `trigger_stats['trigger_rate_pct']`. |
| `templates/pr-body-initial.md` | New Trigger section at the top: When, Window, Rate, Samples, Threshold — filled by the watcher at PR creation, immutable by both phases. |
| `prompts/01-investigate.md` | Added rule: "The Trigger section records the rate at the moment the watcher fired. Do not overwrite it." Updated the `gh pr edit` template to preserve it. |

**Verified:** PR #22's body shows `## Trigger` with values matching the watcher log line (`50%`, `210 samples`, `1-minute lookback`).

---

## Issue 1 — Phase 2 git exit 128

**Root cause:** Phase 2 tried to push to the incident branch but the local state was stale or conflicted with the remote. The runner had no mechanism to align before Claude started making commits.

**Changes:**

| File | Change |
|------|--------|
| `claude-runner/invoke.sh` | Added branch-prep step for Phase 2: `fetch origin --prune`, then checkout + `reset --hard` to remote state. Both phases now `cd` into the workspace. Path is configurable via `WORKSPACE_CLONE_DIR` env. Max-turns raised to 20. Added `Bash(gh pr view*)` to both phases' allowedTools. |
| `alert-watcher/main.py` | Added `ensure_workspace_clone()` at startup — clones the fork into `/workspace/ecommerce` if not present, fetches if already cloned. `open_draft_pr()` and `unique_branch_name()` now operate on the workspace clone. `run_phase()` spawns the runner via `docker run` with proper volume mounts. |
| `alert-watcher/Dockerfile` | Added Docker CLI installation (needed to spawn runner containers). Removed non-root user (Docker socket access). |
| `docker-compose.yml` | Added `network_mode: host` to runner service. Added workspace volume, Docker socket mount, kubeconfig mount, and `RUNNER_IMAGE`/host-path env vars to alert-watcher. |

**Verified:** Phase 2 of PR #22 run exited 0 (no exit 128). The branch-prep step successfully checked out and reset to remote state.

---

## End-to-end run results (PR #22)

| Metric | Value |
|--------|-------|
| PR number | 22 |
| Fingerprint | `6e14cf73` |
| Branch | `incident/6e14cf73-2` |
| PR state | Draft, `incident:fix-proposed` |
| Phase 1 duration | 244.8s |
| Phase 2 duration | 95.5s |
| Phase 1 cost | $0.35 |
| Phase 2 cost | $0.30 |
| Phase 1 turns | 21/20 (hit max-turns) |
| Phase 2 turns | 21/20 (hit max-turns) |
| incidents.jsonl | 1 line, phase2 = 95.5s |
| Trigger section in PR body | Correct (50%, 210 samples, 1-min) |
| PR still draft | Yes |
| kubectl worked | Yes (Phase 1 ran `kubectl get pods -n ecommerce`) |

---

## Known remaining issues

### 1. Max-turns insufficient (20 is not enough)

Both phases hit the turn limit (21 turns used out of 20 max). The model (Sonnet 4.6) spends turns on:
- Loading skills via the Skill tool (clickhouse, k8s, gh) — 2-3 turns wasted
- Navigating the filesystem to find source code — 2-3 turns
- Multiple ClickHouse queries for investigation — 8-10 turns
- Writing findings to PR / committing code — 3-5 turns

**Impact:** Phase 1 investigated correctly but didn't write findings to the PR body before running out. Phase 2 analyzed the bug but didn't commit/push the fix.

**Recommendation:** Raise to 25, OR switch to a model that uses fewer turns, OR add a CLAUDE.md to the workspace clone with explicit navigation hints (e.g., "source is at `otel-demo/ecommerce/backend/src/`").

### 2. Error rate plateau at ~20% with current load generator

The load generator's design (product-7 burst every 3rd round, 11 other high-stock products) produces a natural error rate ceiling of ~20%. This is below the 0.25 threshold.

**Workaround for testing:** Temporarily set `THRESHOLD = 0.15` in main.py.

**Proper fix:** Either increase the burst frequency in the load generator, or reduce stock on more products, or lower the threshold to 0.20.

### 3. ClickHouse table loss on pod restart

ClickHouse runs without persistent storage. If the pod restarts, all `otel_*` tables are lost. The OTel bridge's `create_schema: true` recreates them on reconnect, but existing data is gone and the first minute after restart has no data.

**Workaround:** Restart `otel-clickhouse-bridge` after a ClickHouse restart. Consider adding a PVC to the ClickHouse deployment.

### 4. Asciinema cast and evidence capture not yet done

The brief requests:
- `casts/full-incident-v0-2.cast`
- `evidence/post-05/` with phase1.jsonl, phase2.jsonl, incidents.jsonl, pr-metadata.json, SUMMARY.md

These require a fully clean run where both phases complete within turns. Blocked by issue #1 above.

---

## Files changed (7 total)

```
watcher-example/alert-watcher/Dockerfile      — Docker CLI, root user
watcher-example/alert-watcher/main.py         — trigger stats, docker run, workspace clone, error detail
watcher-example/claude-runner/Dockerfile      — ENV KUBECONFIG
watcher-example/claude-runner/invoke.sh       — preflight, branch-prep, workspace cd, allowedTools, max-turns
watcher-example/docker-compose.yml            — network_mode, volumes, env vars
watcher-example/prompts/01-investigate.md     — Trigger section preservation rule
watcher-example/templates/pr-body-initial.md  — Trigger section template
```

---

## Next steps

1. **Raise max-turns to 25** and re-run clean. Or add a `CLAUDE.md` to the workspace clone with hints to reduce wasted turns.
2. Once a clean run succeeds end-to-end (both phases complete, fix committed, PR body written), capture the evidence artifacts.
3. Record the asciinema cast during the clean run.
4. Consider persisting ClickHouse data for reliability.
