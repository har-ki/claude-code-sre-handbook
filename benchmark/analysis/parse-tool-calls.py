#!/usr/bin/env python3
"""Analyze trace.jsonl files for tool-call reliability metrics.

Usage:
    python3 parse-tool-calls.py <run-dir>

Reads trace.jsonl files from a k8s-ai-bench run directory and reports:
- Total Bash tool-use blocks per task
- kubectl invocations (subset)
- Malformed / error tool calls + rate
- Verbatim malformation examples
- Context-overflow signals
"""
import json
import os
import sys
from pathlib import Path


def parse_trace(trace_path):
    """Parse a single trace.jsonl and return tool-call metrics."""
    tool_uses = []       # list of {name, command, tool_use_id}
    tool_results = {}    # tool_use_id -> {content, is_error, stdout, stderr}
    malformed_lines = 0
    total_lines = 0
    context_overflow = False
    stop_reason = None

    with open(trace_path) as f:
        for line in f:
            total_lines += 1
            stripped = line.strip()
            if not stripped:
                continue
            try:
                event = json.loads(stripped)
            except json.JSONDecodeError:
                malformed_lines += 1
                continue

            etype = event.get("type", "")

            if etype == "assistant":
                content = event.get("message", {}).get("content", [])
                for item in content:
                    if item.get("type") == "tool_use":
                        tool_uses.append({
                            "name": item.get("name", ""),
                            "input": item.get("input", {}),
                            "id": item.get("id", ""),
                        })

            elif etype == "user":
                msg_content = event.get("message", {}).get("content", [])
                tool_use_result = event.get("tool_use_result", {})
                if not isinstance(tool_use_result, dict):
                    tool_use_result = {}
                for item in msg_content:
                    if item.get("type") == "tool_result":
                        tid = item.get("tool_use_id", "")
                        tool_results[tid] = {
                            "content": item.get("content", ""),
                            "is_error": item.get("is_error", False),
                            "stdout": tool_use_result.get("stdout", ""),
                            "stderr": tool_use_result.get("stderr", ""),
                        }

            elif etype == "result":
                stop_reason = event.get("stop_reason", "")
                if stop_reason == "max_tokens":
                    context_overflow = True

    return {
        "total_lines": total_lines,
        "tool_uses": tool_uses,
        "tool_results": tool_results,
        "malformed_lines": malformed_lines,
        "context_overflow": context_overflow,
        "stop_reason": stop_reason,
    }


def classify_tool_calls(parsed):
    """Classify tool calls into categories and detect malformations."""
    bash_calls = []
    kubectl_calls = []
    malformed_calls = []
    error_results = []

    for tu in parsed["tool_uses"]:
        if tu["name"] != "Bash":
            continue

        cmd = tu["input"].get("command", "")
        bash_calls.append(tu)

        if cmd.strip().startswith("kubectl"):
            kubectl_calls.append(tu)

        # Check if the tool result was an error
        result = parsed["tool_results"].get(tu["id"], {})
        if result.get("is_error", False):
            error_results.append({
                "command": cmd,
                "error": result.get("content", result.get("stderr", "")),
            })

        # Check for malformed commands (empty or clearly broken)
        if not cmd.strip():
            malformed_calls.append({
                "command": cmd,
                "reason": "empty command",
            })

    return {
        "bash_total": len(bash_calls),
        "kubectl_total": len(kubectl_calls),
        "malformed": malformed_calls,
        "errors": error_results,
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: parse-tool-calls.py <run-dir>", file=sys.stderr)
        sys.exit(1)

    run_dir = Path(sys.argv[1])
    if not run_dir.is_dir():
        print(f"Error: {run_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    # Find all trace.jsonl files
    trace_files = sorted(run_dir.rglob("trace.jsonl"))
    if not trace_files:
        print(f"No trace.jsonl files found in {run_dir}", file=sys.stderr)
        sys.exit(1)

    # Aggregate metrics
    total_bash = 0
    total_kubectl = 0
    total_malformed = 0
    total_errors = 0
    total_context_overflow = 0
    all_error_examples = []
    all_malformed_examples = []

    print(f"# Tool-Call Analysis: {run_dir.name}")
    print()
    print("| Task | Bash calls | kubectl | Errors | Malformed | Overflow |")
    print("|------|-----------|---------|--------|-----------|----------|")

    for tf in trace_files:
        # Derive task name from path: .../iteration-N/task-name/trace.jsonl
        task_name = tf.parent.name

        parsed = parse_trace(tf)
        classified = classify_tool_calls(parsed)

        total_bash += classified["bash_total"]
        total_kubectl += classified["kubectl_total"]
        total_malformed += len(classified["malformed"])
        total_errors += len(classified["errors"])
        if parsed["context_overflow"]:
            total_context_overflow += 1

        overflow_flag = "YES" if parsed["context_overflow"] else "-"
        print(f"| {task_name} | {classified['bash_total']} | "
              f"{classified['kubectl_total']} | {len(classified['errors'])} | "
              f"{len(classified['malformed'])} | {overflow_flag} |")

        # Collect examples
        for e in classified["errors"][:2]:
            all_error_examples.append({"task": task_name, **e})
        for m in classified["malformed"][:2]:
            all_malformed_examples.append({"task": task_name, **m})

    print()
    print("## Aggregate")
    print()
    total_calls = total_bash
    malformed_rate = (
        f"{(total_malformed + total_errors) / total_calls * 100:.1f}%"
        if total_calls > 0 else "N/A"
    )
    print(f"- **Total Bash tool calls:** {total_bash}")
    print(f"- **kubectl invocations:** {total_kubectl}")
    print(f"- **Error results:** {total_errors}")
    print(f"- **Malformed commands:** {total_malformed}")
    print(f"- **Malformation rate:** {malformed_rate}")
    print(f"- **Context overflow events:** {total_context_overflow}")

    if all_error_examples:
        print()
        print("## Error Examples")
        print()
        for i, ex in enumerate(all_error_examples[:3], 1):
            print(f"**{i}. {ex['task']}**")
            print(f"```")
            print(f"Command: {ex.get('command', 'N/A')}")
            print(f"Error:   {ex.get('error', 'N/A')[:200]}")
            print(f"```")
            print()

    if all_malformed_examples:
        print()
        print("## Malformed Command Examples")
        print()
        for i, ex in enumerate(all_malformed_examples[:3], 1):
            print(f"**{i}. {ex['task']}**")
            print(f"```")
            print(f"Command: {repr(ex.get('command', ''))}")
            print(f"Reason:  {ex.get('reason', 'N/A')}")
            print(f"```")
            print()


if __name__ == "__main__":
    main()
