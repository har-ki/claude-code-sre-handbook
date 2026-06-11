#!/usr/bin/env python3
"""Analyze Post 10 canonical experiment results.

Usage:
    # Analyze all arms from a single experiment session:
    python3 analyze-canonical.py benchmark/data/runs/*_canonical-*

    # Analyze one arm:
    python3 analyze-canonical.py benchmark/data/runs/20260610T120000_sonnet_canonical-A

Reads trace.jsonl from each run directory, extracts metrics, computes
per-arm path variance, and outputs a summary table.
"""

import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path


def parse_trace(trace_path: str) -> dict:
    """Extract metrics from a single run's trace.jsonl."""
    events = []
    with open(trace_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    # --- Extract tool calls and result-level metrics ---
    tool_calls = []
    total_input_tokens = 0
    total_output_tokens = 0
    cache_read_tokens = 0
    cache_creation_tokens = 0
    wall_time_ms = None
    num_turns = None
    total_cost_usd = None

    for event in events:
        etype = event.get("type", "")

        if etype == "result":
            # Result event has authoritative totals
            usage = event.get("usage", {})
            total_input_tokens = usage.get("input_tokens", 0)
            total_output_tokens = usage.get("output_tokens", 0)
            cache_read_tokens = usage.get("cache_read_input_tokens", 0)
            cache_creation_tokens = usage.get("cache_creation_input_tokens", 0)
            wall_time_ms = event.get("duration_ms")
            num_turns = event.get("num_turns")
            total_cost_usd = event.get("total_cost_usd")

        elif etype == "assistant":
            msg = event.get("message", {})

            # Extract tool_use content blocks (all tools, not just Bash)
            for block in msg.get("content", []):
                if block.get("type") == "tool_use":
                    tool_calls.append({
                        "name": block.get("name", ""),
                        "input": block.get("input", {}),
                    })
                elif block.get("type") == "server_tool_use":
                    tool_calls.append({
                        "name": block.get("name", ""),
                        "input": block.get("input", {}),
                    })

    # --- Classify tool calls ---
    command_categories = []
    files_inspected = set()
    commands_raw = []

    for tc in tool_calls:
        tool_name = tc.get("name", "")
        inp = tc.get("input", {})
        cmd = inp.get("command", "")
        commands_raw.append(f"{tool_name}:{cmd}" if tool_name != "Bash" else cmd)

        # Classify by tool type first, then by command content for Bash
        if tool_name == "Read":
            command_categories.append("file-read")
            fp = inp.get("file_path", "")
            if fp:
                files_inspected.add(fp)
        elif tool_name == "Glob":
            command_categories.append("listing")
        elif tool_name == "Grep":
            command_categories.append("search")
        elif tool_name != "Bash" and tool_name:
            command_categories.append("other")
        elif not cmd:
            command_categories.append("other")
        # Bash command classification
        elif "clickhouse client" in cmd or "clickhouse-client" in cmd:
            command_categories.append("clickhouse")
        elif re.search(r'\bkubectl\b', cmd):
            command_categories.append("kubectl")
        elif re.search(r'\b(cat|head|tail|less|more)\b', cmd) or cmd.strip().startswith("cat "):
            command_categories.append("file-read")
            parts = cmd.strip().split()
            for p in parts[1:]:
                if not p.startswith("-"):
                    files_inspected.add(p)
        elif re.search(r'\bgrep\b', cmd) or re.search(r'\brg\b', cmd):
            command_categories.append("search")
        elif re.search(r'\b(ls|find|tree)\b', cmd):
            command_categories.append("listing")
        elif re.search(r'\bcurl\b', cmd):
            command_categories.append("http")
        else:
            command_categories.append("other")

    # Wall time from result event (ms -> s)
    wall_time_seconds = round(wall_time_ms / 1000, 1) if wall_time_ms else None

    # Total input = direct + cache_read + cache_creation
    effective_input_tokens = total_input_tokens + cache_read_tokens + cache_creation_tokens

    return {
        "total_tool_calls": len(tool_calls),
        "tool_calls_to_rc": len(tool_calls),  # default: total (manual review refines)
        "num_turns": num_turns,
        "command_categories": command_categories,
        "distinct_categories": len(set(command_categories)),
        "files_inspected": sorted(files_inspected),
        "distinct_files": len(files_inspected),
        "exploration_breadth": len(set(command_categories)) + len(files_inspected),
        "commands_raw": commands_raw,
        "input_tokens": effective_input_tokens,
        "output_tokens": total_output_tokens,
        "cache_read_tokens": cache_read_tokens,
        "cache_creation_tokens": cache_creation_tokens,
        "cost_usd": round(total_cost_usd, 4) if total_cost_usd else None,
        "wall_time_seconds": wall_time_seconds,
        "catch_completeness": "MANUAL_REVIEW",
        "over_constraint": "MANUAL_REVIEW",
    }


def jaccard_distance(sets: list[set]) -> float:
    """Compute mean pairwise Jaccard distance across a list of sets."""
    if len(sets) < 2:
        return 0.0
    distances = []
    for i in range(len(sets)):
        for j in range(i + 1, len(sets)):
            union = sets[i] | sets[j]
            inter = sets[i] & sets[j]
            if len(union) == 0:
                distances.append(0.0)
            else:
                distances.append(1.0 - len(inter) / len(union))
    return sum(distances) / len(distances)


def coefficient_of_variation(values: list[float]) -> float:
    """CV = std / mean. Returns 0 if mean is 0."""
    if not values:
        return 0.0
    mean = sum(values) / len(values)
    if mean == 0:
        return 0.0
    variance = sum((v - mean) ** 2 for v in values) / len(values)
    return (variance ** 0.5) / mean


def compute_arm_variance(run_metrics: list[dict]) -> dict:
    """Compute path variance metrics across runs within an arm."""
    # Jaccard distance on command sequences (as sets of "category:index" pairs)
    category_sets = []
    for m in run_metrics:
        # Use indexed categories to preserve order information
        cat_set = set()
        for i, cat in enumerate(m["command_categories"]):
            cat_set.add(f"{i}:{cat}")
        category_sets.append(cat_set)

    # Also compute Jaccard on unordered category bags
    unordered_sets = [set(m["command_categories"]) for m in run_metrics]

    # Tool call count CV
    tc_counts = [float(m["total_tool_calls"]) for m in run_metrics]

    return {
        "ordered_jaccard": round(jaccard_distance(category_sets), 3),
        "unordered_jaccard": round(jaccard_distance(unordered_sets), 3),
        "tool_call_cv": round(coefficient_of_variation(tc_counts), 3),
        "tool_call_counts": tc_counts,
        "tool_call_mean": round(sum(tc_counts) / len(tc_counts), 1) if tc_counts else 0,
    }


def format_summary(all_results: dict, output_path: str):
    """Write markdown summary table."""
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")

    lines = [
        f"# Post 10 Canonical Experiment — Summary",
        f"",
        f"Generated: {timestamp}",
        f"",
        f"## Per-Run Results",
        f"",
        f"| Arm | Run | Tool Calls | Turns | Distinct Categories | Files Inspected | Input Tokens | Output Tokens | Cost (USD) | Wall Time (s) | Catch | Over-constraint |",
        f"|-----|-----|-----------|-------|--------------------|-----------------|--------------|--------------|-----------:|--------------:|-------|-----------------|",
    ]

    for arm in ["A", "B", "C"]:
        if arm not in all_results:
            continue
        for i, m in enumerate(all_results[arm]["runs"], 1):
            wt = f"{m['wall_time_seconds']}" if m["wall_time_seconds"] else "N/A"
            cost = f"${m['cost_usd']:.4f}" if m.get("cost_usd") else "N/A"
            lines.append(
                f"| {arm} | {i} | {m['total_tool_calls']} | {m.get('num_turns', 'N/A')} | {m['distinct_categories']} "
                f"| {m['distinct_files']} | {m['input_tokens']:,} | {m['output_tokens']:,} "
                f"| {cost} | {wt} | {m['catch_completeness']} | {m['over_constraint']} |"
            )

    lines.extend([
        "",
        "## Path Variance (per arm)",
        "",
        "| Arm | Mean Tool Calls | Tool Call CV | Ordered Jaccard | Unordered Jaccard |",
        "|-----|----------------|-------------|-----------------|-------------------|",
    ])

    for arm in ["A", "B", "C"]:
        if arm not in all_results:
            continue
        v = all_results[arm]["variance"]
        lines.append(
            f"| {arm} | {v['tool_call_mean']} | {v['tool_call_cv']} "
            f"| {v['ordered_jaccard']} | {v['unordered_jaccard']} |"
        )

    lines.extend([
        "",
        "## Metric Definitions",
        "",
        "- **Tool Calls**: Total Bash tool invocations in the run",
        "- **Distinct Categories**: Number of unique command types (kubectl, clickhouse, file-read, search, listing, http, other)",
        "- **Files Inspected**: Distinct file paths read via cat/head/tail",
        "- **Tool Call CV**: Coefficient of variation of tool-call counts within an arm (lower = more repeatable)",
        "- **Ordered Jaccard**: Mean pairwise Jaccard distance of indexed command sequences (higher = more divergent paths)",
        "- **Unordered Jaccard**: Mean pairwise Jaccard distance of command category sets (higher = different tool mix)",
        "- **Catch**: MANUAL_REVIEW — assign full (race + non-atomic decrement), partial (one only), or wrong",
        "- **Over-constraint**: MANUAL_REVIEW — flag if runbook caused a skipped-but-needed step",
        "",
    ])

    with open(output_path, "w") as f:
        f.write("\n".join(lines))

    print(f"Summary written to: {output_path}")


def write_jsonl(all_results: dict, output_dir: str):
    """Write per-run JSONL rows."""
    os.makedirs(output_dir, exist_ok=True)
    date_part = datetime.now().strftime("%Y%m%d")

    for arm in ["A", "B", "C"]:
        if arm not in all_results:
            continue
        for i, m in enumerate(all_results[arm]["runs"], 1):
            row = {
                "timestamp": datetime.now().strftime("%Y%m%dT%H%M%S"),
                "experiment": "canonical",
                "arm": arm,
                "run": i,
                "total_tool_calls": m["total_tool_calls"],
                "distinct_categories": m["distinct_categories"],
                "distinct_files": m["distinct_files"],
                "exploration_breadth": m["exploration_breadth"],
                "input_tokens": m["input_tokens"],
                "output_tokens": m["output_tokens"],
                "wall_time_seconds": m["wall_time_seconds"],
                "catch_completeness": m["catch_completeness"],
                "over_constraint": m["over_constraint"],
            }
            filename = f"{date_part}-T-canonical-{arm}-run{i}.jsonl"
            filepath = os.path.join(output_dir, filename)
            with open(filepath, "w") as f:
                f.write(json.dumps(row) + "\n")

    print(f"JSONL rows written to: {output_dir}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    # Collect run directories grouped by arm
    all_results = {}  # arm -> {"runs": [...], "variance": {...}}

    for arg in sys.argv[1:]:
        arm_dir = Path(arg)
        if not arm_dir.is_dir():
            print(f"WARNING: {arg} is not a directory, skipping", file=sys.stderr)
            continue

        # Detect arm from directory name (e.g. ..._canonical-A)
        dirname = arm_dir.name
        arm_match = re.search(r'canonical-([ABC])$', dirname)
        if not arm_match:
            print(f"WARNING: Cannot detect arm from '{dirname}', skipping", file=sys.stderr)
            continue

        arm = arm_match.group(1)

        # Find run subdirectories
        run_dirs = sorted(arm_dir.glob("run-*"))
        if not run_dirs:
            print(f"WARNING: No run-* subdirectories in {arm_dir}", file=sys.stderr)
            continue

        run_metrics = []
        for rd in run_dirs:
            trace_file = rd / "trace.jsonl"
            if not trace_file.exists():
                print(f"WARNING: No trace.jsonl in {rd}, skipping", file=sys.stderr)
                continue
            metrics = parse_trace(str(trace_file))
            run_metrics.append(metrics)

        if not run_metrics:
            continue

        variance = compute_arm_variance(run_metrics)
        all_results[arm] = {"runs": run_metrics, "variance": variance}

    if not all_results:
        print("ERROR: No valid run data found", file=sys.stderr)
        sys.exit(1)

    # Determine repo root for output paths
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent

    # Write outputs
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    summary_path = repo_root / "benchmark" / "analysis" / f"{timestamp}-canonical-summary.md"
    os.makedirs(summary_path.parent, exist_ok=True)
    format_summary(all_results, str(summary_path))

    raw_dir = repo_root / "benchmark" / "data" / "raw"
    write_jsonl(all_results, str(raw_dir))

    # Print quick summary to stdout
    print("")
    print("=== Quick Summary ===")
    for arm in ["A", "B", "C"]:
        if arm not in all_results:
            continue
        v = all_results[arm]["variance"]
        runs = all_results[arm]["runs"]
        label = {"A": "No Skill", "B": "Thin Skill", "C": "Full Runbook"}[arm]
        tc = [r["total_tool_calls"] for r in runs]
        print(f"  Arm {arm} ({label}): tool calls {tc}, CV={v['tool_call_cv']}, "
              f"ordered_jaccard={v['ordered_jaccard']}")


if __name__ == "__main__":
    main()
