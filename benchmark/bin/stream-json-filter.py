#!/usr/bin/env python3
"""Demux Claude Code stream-json into trace.jsonl + human-readable stdout.

Usage:
    echo "$PROMPT" | claude -p --output-format stream-json --verbose ... \
        | python3 stream-json-filter.py /path/to/trace.jsonl

Every raw JSON line is written verbatim to the trace file.
Human-readable text (assistant prose + tool output) goes to stdout
so k8s-ai-bench can capture it as log.txt.
"""
import json
import os
import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: stream-json-filter.py <trace-jsonl-path>", file=sys.stderr)
        sys.exit(1)

    trace_path = sys.argv[1]
    os.makedirs(os.path.dirname(trace_path) or ".", exist_ok=True)

    with open(trace_path, "w") as trace_f:
        for raw_line in sys.stdin:
            # Always write raw line to trace file
            trace_f.write(raw_line)
            trace_f.flush()

            stripped = raw_line.strip()
            if not stripped:
                continue

            try:
                event = json.loads(stripped)
            except json.JSONDecodeError:
                # Graceful degradation: emit unparseable lines to stdout too
                sys.stdout.write(raw_line)
                sys.stdout.flush()
                continue

            etype = event.get("type", "")

            if etype == "assistant":
                # Emit text content blocks from assistant messages
                content = event.get("message", {}).get("content", [])
                for item in content:
                    if item.get("type") == "text":
                        text = item.get("text", "")
                        if text:
                            sys.stdout.write(text)
                            sys.stdout.flush()

            elif etype == "user":
                # Emit tool results (kubectl/bash output)
                tool_result = event.get("tool_use_result", {})
                if isinstance(tool_result, str):
                    if tool_result:
                        sys.stdout.write(tool_result)
                        if not tool_result.endswith("\n"):
                            sys.stdout.write("\n")
                        sys.stdout.flush()
                elif isinstance(tool_result, dict):
                    stdout_text = tool_result.get("stdout", "")
                    if stdout_text:
                        sys.stdout.write(stdout_text)
                        if not stdout_text.endswith("\n"):
                            sys.stdout.write("\n")
                        sys.stdout.flush()
                    stderr_text = tool_result.get("stderr", "")
                    if stderr_text:
                        sys.stdout.write(stderr_text)
                        if not stderr_text.endswith("\n"):
                            sys.stdout.write("\n")
                        sys.stdout.flush()

            # All other types (system, result, rate_limit_event) -> trace only


if __name__ == "__main__":
    main()
