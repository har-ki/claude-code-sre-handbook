#!/usr/bin/env python3
"""Parse a Claude Code trace.jsonl for memory-related tool activity.

Usage:
    python3 parse-memory-trace.py <trace.jsonl> <mode>

Modes:
    stack-probe  — check whether file tools are available and memory dir was accessed
    drive-test   — extract memory-directory operation details

Claude Code has no dedicated "Memory" tool. Memory is implemented via standard
file tools (Read, Write, Edit, Bash, Glob) operating on a memory directory
(typically ~/.claude/projects/.../memory/). This parser detects file operations
that target memory-related paths.

The memory path pattern is configurable via MEMORY_PATH_PATTERN env var
(default: memory|/memories|MEMORY.md).
"""
import json
import os
import re
import sys

# Tools that can perform file operations
FILE_TOOLS = {"Bash", "Read", "Write", "Edit", "Glob", "Grep"}


def _memory_path_pattern():
    raw = os.environ.get("MEMORY_PATH_PATTERN", r"memory|/memories|MEMORY\.md")
    return re.compile(raw, re.IGNORECASE)


def _extract_paths_from_input(tool_name, tool_input):
    """Extract file paths or commands from a tool_use input block."""
    paths = []
    if isinstance(tool_input, dict):
        # Read/Write/Edit/Glob have file_path or path
        for key in ("file_path", "path", "pattern"):
            val = tool_input.get(key, "")
            if val:
                paths.append(str(val))
        # Bash has command
        cmd = tool_input.get("command", "")
        if cmd:
            paths.append(str(cmd))
    elif isinstance(tool_input, str):
        paths.append(tool_input)
    return paths


def _is_memory_operation(tool_name, tool_input, pattern):
    """Check if a tool_use block targets a memory-related path."""
    if tool_name not in FILE_TOOLS:
        return False
    paths = _extract_paths_from_input(tool_name, tool_input)
    return any(pattern.search(p) for p in paths)


def _classify_operation(tool_name, tool_input):
    """Classify a memory operation as 'read' or 'write'."""
    if tool_name in ("Read", "Glob", "Grep"):
        return "read"
    if tool_name == "Write":
        return "write"
    if tool_name == "Edit":
        return "write"
    if tool_name == "Bash":
        cmd = tool_input.get("command", "") if isinstance(tool_input, dict) else str(tool_input)
        # Heuristic: ls, cat, head, find, grep → read; echo, tee, cp, mv, mkdir → write
        read_cmds = ("ls ", "cat ", "head ", "tail ", "find ", "grep ", "rg ", "wc ")
        write_cmds = ("echo ", "tee ", "cp ", "mv ", "mkdir ", "rm ", "touch ")
        cmd_stripped = cmd.lstrip()
        for rc in read_cmds:
            if cmd_stripped.startswith(rc):
                return "read"
        for wc in write_cmds:
            if cmd_stripped.startswith(wc):
                return "write"
        return "read"  # default for unknown bash commands
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
    """Check whether file tools are available and memory directory was accessed."""
    file_tools_present = []
    memory_access_emitted = False
    memory_operations = []
    all_tools = []
    error = None

    for event in _parse_events(trace_path):
        etype = event.get("type", "")

        # Check system init for tools list
        if etype == "system" and event.get("subtype") == "init":
            tools = event.get("tools", [])
            for tool in tools:
                tool_name = tool if isinstance(tool, str) else tool.get("name", "")
                all_tools.append(tool_name)
                if tool_name in FILE_TOOLS:
                    file_tools_present.append(tool_name)

        # Check assistant messages for tool_use blocks targeting memory paths
        if etype == "assistant":
            content = event.get("message", {}).get("content", [])
            for block in content:
                if block.get("type") != "tool_use":
                    continue
                tool_name = block.get("name", "")
                tool_input = block.get("input", {})
                if _is_memory_operation(tool_name, tool_input, pattern):
                    memory_access_emitted = True
                    classification = _classify_operation(tool_name, tool_input)
                    paths = _extract_paths_from_input(tool_name, tool_input)
                    memory_operations.append({
                        "tool": tool_name,
                        "type": classification,
                        "target": paths[0] if paths else "",
                    })

        # Check for errors
        if etype == "error":
            error = event.get("error", {}).get("message", str(event))

    result = {
        "file_tools_present": sorted(set(file_tools_present)),
        "memory_access_emitted": memory_access_emitted,
        "memory_operations": memory_operations,
        "total_tools_available": len(all_tools),
        "error": error,
    }

    print(json.dumps(result))


def drive_test(trace_path, pattern):
    """Extract memory-directory operation details for the drive test."""
    tool_calls = 0
    tool_call_sequence = []
    malformed = 0
    first_memory_call_is_read = None
    wrote_coherent = False

    for event in _parse_events(trace_path):
        etype = event.get("type", "")

        if etype != "assistant":
            continue

        content = event.get("message", {}).get("content", [])
        for block in content:
            if block.get("type") != "tool_use":
                continue
            tool_name = block.get("name", "")
            tool_input = block.get("input", {})

            if not _is_memory_operation(tool_name, tool_input, pattern):
                continue

            tool_calls += 1
            classification = _classify_operation(tool_name, tool_input)
            tool_call_sequence.append(classification)

            if first_memory_call_is_read is None:
                first_memory_call_is_read = classification == "read"

            # Check for malformed input
            if not tool_input or (
                isinstance(tool_input, dict) and not any(tool_input.values())
            ):
                malformed += 1

            # Check wrote_coherent: write operation with substantial content
            if classification == "write" and not wrote_coherent:
                if tool_name == "Write":
                    content_val = tool_input.get("content", "") if isinstance(tool_input, dict) else ""
                    if len(str(content_val)) > 20:
                        wrote_coherent = True
                elif tool_name == "Edit":
                    new_str = tool_input.get("new_string", "") if isinstance(tool_input, dict) else ""
                    if len(str(new_str)) > 20:
                        wrote_coherent = True
                elif tool_name == "Bash":
                    cmd = tool_input.get("command", "") if isinstance(tool_input, dict) else str(tool_input)
                    if len(cmd) > 30:
                        wrote_coherent = True

    checked_first = bool(first_memory_call_is_read) if first_memory_call_is_read is not None else False

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

    pattern = _memory_path_pattern()

    if mode == "stack-probe":
        stack_probe(trace_path, pattern)
    elif mode == "drive-test":
        drive_test(trace_path, pattern)
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
