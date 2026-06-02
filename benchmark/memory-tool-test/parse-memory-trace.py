#!/usr/bin/env python3
"""Parse a Claude Code trace.jsonl for memory-tool signals.

Usage:
    python3 parse-memory-trace.py <trace.jsonl> <mode>

Modes:
    stack-probe  — check whether memory tool is advertised and used
    drive-test   — extract memory tool call details (checked_first, wrote_coherent, etc.)

The tool name pattern is configurable via MEMORY_TOOL_PATTERN (default: memory, case-insensitive).
"""
import json
import os
import re
import sys


def _tool_pattern():
    raw = os.environ.get("MEMORY_TOOL_PATTERN", "memory")
    return re.compile(raw, re.IGNORECASE)


def _is_memory_tool(name, pattern):
    return bool(pattern.search(name))


def _classify_tool_call(name):
    """Classify a memory tool call as 'read' or 'write' based on name heuristics."""
    lower = name.lower()
    for keyword in ("read", "get", "list", "search", "fetch", "check"):
        if keyword in lower:
            return "read"
    for keyword in ("write", "create", "save", "store", "put", "update", "set"):
        if keyword in lower:
            return "write"
    # Default: if the name just contains "memory" without a verb, treat as read
    return "read"


def _parse_events(trace_path):
    """Yield parsed JSON events from a trace.jsonl file."""
    with open(trace_path) as f:
        for line in f:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                yield json.loads(stripped)
            except json.JSONDecodeError:
                continue


def stack_probe(trace_path, pattern):
    """Check whether the memory tool type is advertised and emitted."""
    tool_type_present = False
    tool_use_emitted = False
    error = None
    tools_found = []

    for event in _parse_events(trace_path):
        etype = event.get("type", "")

        # Check system init for tools list
        if etype == "system" and event.get("subtype") == "init":
            tools = event.get("tools", [])
            for tool in tools:
                tool_name = tool if isinstance(tool, str) else tool.get("name", "")
                if _is_memory_tool(tool_name, pattern):
                    tool_type_present = True
                    tools_found.append(tool_name)

        # Check assistant messages for tool_use blocks
        if etype == "assistant":
            content = event.get("message", {}).get("content", [])
            for block in content:
                if block.get("type") == "tool_use":
                    tool_name = block.get("name", "")
                    if _is_memory_tool(tool_name, pattern):
                        tool_use_emitted = True

        # Check for errors
        if etype == "error":
            error = event.get("error", {}).get("message", str(event))

    if not tool_type_present and not tools_found:
        print(
            f"WARNING: No memory tool found in tools list (pattern: {pattern.pattern})",
            file=sys.stderr,
        )

    result = {
        "tool_type_present": tool_type_present,
        "tool_use_emitted": tool_use_emitted,
        "error": error,
    }
    if tools_found:
        result["memory_tool_names"] = tools_found

    print(json.dumps(result))


def drive_test(trace_path, pattern):
    """Extract memory tool call details for the drive test."""
    tool_calls = 0
    tool_call_sequence = []
    malformed = 0
    first_memory_call_is_read = None

    for event in _parse_events(trace_path):
        etype = event.get("type", "")

        if etype == "assistant":
            content = event.get("message", {}).get("content", [])
            for block in content:
                if block.get("type") != "tool_use":
                    continue
                tool_name = block.get("name", "")
                if not _is_memory_tool(tool_name, pattern):
                    continue

                tool_calls += 1
                classification = _classify_tool_call(tool_name)
                tool_call_sequence.append(classification)

                if first_memory_call_is_read is None:
                    first_memory_call_is_read = classification == "read"

                # Check for malformed input
                tool_input = block.get("input", {})
                if not tool_input or (
                    isinstance(tool_input, dict) and not any(tool_input.values())
                ):
                    malformed += 1

    checked_first = bool(first_memory_call_is_read) if first_memory_call_is_read is not None else False

    # wrote_coherent: any write call has non-trivial input
    wrote_coherent = False
    call_idx = 0
    for event in _parse_events(trace_path):
        if event.get("type") != "assistant":
            continue
        for block in event.get("message", {}).get("content", []):
            if block.get("type") != "tool_use":
                continue
            tool_name = block.get("name", "")
            if not _is_memory_tool(tool_name, pattern):
                continue
            if _classify_tool_call(tool_name) == "write":
                tool_input = block.get("input", {})
                input_str = json.dumps(tool_input) if isinstance(tool_input, dict) else str(tool_input)
                if len(input_str) > 20:
                    wrote_coherent = True
                    break
            call_idx += 1
        if wrote_coherent:
            break

    result = {
        "checked_first": checked_first,
        "wrote_coherent": wrote_coherent,
        "tool_calls": tool_calls,
        "tool_call_sequence": tool_call_sequence,
        "malformed": malformed,
    }
    print(json.dumps(result))


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <trace.jsonl> <stack-probe|drive-test>", file=sys.stderr)
        sys.exit(1)

    trace_path = sys.argv[1]
    mode = sys.argv[2]

    if not os.path.isfile(trace_path):
        print(json.dumps({"error": f"Trace file not found: {trace_path}"}))
        sys.exit(1)

    pattern = _tool_pattern()

    if mode == "stack-probe":
        stack_probe(trace_path, pattern)
    elif mode == "drive-test":
        drive_test(trace_path, pattern)
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
