#!/usr/bin/env python3
"""Transparent logging proxy between Claude Code and Ollama.

Forwards all HTTP traffic unmodified while extracting inference metrics
(token counts, TTFT, duration) from responses.

Usage:
    python3 inference-proxy.py \
        --listen-port 11500 \
        --upstream http://localhost:11434 \
        --metrics-file /path/to/inference-metrics.jsonl \
        --task-name-file /tmp/benchmark-current-task.txt
"""
import argparse
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class ProxyHandler(BaseHTTPRequestHandler):
    upstream_base = ""
    metrics_file = ""
    task_name_file = ""
    metrics_lock = threading.Lock()

    def log_message(self, format, *args):
        # Suppress default access logging
        pass

    def _read_task_name(self):
        path = self.server.task_name_file
        if path and os.path.exists(path):
            try:
                with open(path, "r") as f:
                    return f.read().strip()
            except OSError:
                pass
        return "unknown"

    def _write_metric(self, record):
        path = self.server.metrics_file
        if not path:
            return
        with self.server.metrics_lock:
            with open(path, "a") as f:
                f.write(json.dumps(record, default=str) + "\n")
                f.flush()

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self._proxy_request("GET")

    def do_POST(self):
        self._proxy_request("POST")

    def do_PUT(self):
        self._proxy_request("PUT")

    def do_DELETE(self):
        self._proxy_request("DELETE")

    def do_OPTIONS(self):
        self._proxy_request("OPTIONS")

    def _proxy_request(self, method):
        t_start = time.monotonic()
        ts = datetime.now(timezone.utc).isoformat()

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        # Check if streaming is requested
        is_streaming = False
        model_name = ""
        if body:
            try:
                req_json = json.loads(body)
                is_streaming = req_json.get("stream", False)
                model_name = req_json.get("model", "")
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass

        # Build upstream request
        upstream_url = self.server.upstream_base.rstrip("/") + self.path
        headers = {}
        for key in self.headers:
            if key.lower() not in ("host", "transfer-encoding"):
                headers[key] = self.headers[key]

        req = Request(upstream_url, data=body if body else None,
                      headers=headers, method=method)

        try:
            resp = urlopen(req, timeout=600)
        except HTTPError as e:
            self.send_response(e.code)
            for key, val in e.headers.items():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.end_headers()
            self.wfile.write(e.read())
            return
        except URLError as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"Proxy error: {e.reason}".encode())
            return

        # Forward response headers
        self.send_response(resp.status)
        for key, val in resp.headers.items():
            if key.lower() not in ("transfer-encoding", "content-length",
                                    "connection"):
                self.send_header(key, val)

        if is_streaming:
            # Streaming: forward chunks immediately, accumulate for metrics
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            accumulated = []
            t_first_chunk = None
            usage_data = {}

            try:
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    if t_first_chunk is None:
                        t_first_chunk = time.monotonic()

                    # Forward chunk immediately
                    self.wfile.write(f"{len(chunk):x}\r\n".encode())
                    self.wfile.write(chunk)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()

                    # Accumulate for metrics extraction
                    accumulated.append(chunk)

                # Send final zero-length chunk
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

            # Extract metrics from accumulated SSE data
            full_data = b"".join(accumulated).decode("utf-8", errors="replace")
            for line in full_data.split("\n"):
                line = line.strip()
                if line.startswith("data: ") and line != "data: [DONE]":
                    try:
                        chunk_json = json.loads(line[6:])
                        u = chunk_json.get("usage", {})
                        if u:
                            usage_data.update(u)
                        # Also check x_ollama fields
                        x = chunk_json.get("x_ollama", {})
                        if x:
                            usage_data["x_ollama"] = x
                    except json.JSONDecodeError:
                        pass

            t_end = time.monotonic()
            self._write_metric({
                "timestamp": ts,
                "task_name": self._read_task_name(),
                "endpoint": self.path,
                "model": model_name,
                "streaming": True,
                "duration_ms": round((t_end - t_start) * 1000),
                "time_to_first_token_ms": (
                    round((t_first_chunk - t_start) * 1000)
                    if t_first_chunk else None
                ),
                "prompt_tokens": usage_data.get("prompt_tokens") or usage_data.get("input_tokens"),
                "completion_tokens": usage_data.get("completion_tokens") or usage_data.get("output_tokens"),
                "total_tokens": usage_data.get("total_tokens"),
                "raw_usage": usage_data if usage_data else None,
            })

        else:
            # Non-streaming: read full response, extract metrics, forward
            resp_body = resp.read()
            self.send_header("Content-Length", str(len(resp_body)))
            self.end_headers()
            self.wfile.write(resp_body)

            # Extract metrics
            usage_data = {}
            try:
                resp_json = json.loads(resp_body)
                usage_data = resp_json.get("usage", {})
                model_name = model_name or resp_json.get("model", "")
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass

            t_end = time.monotonic()
            self._write_metric({
                "timestamp": ts,
                "task_name": self._read_task_name(),
                "endpoint": self.path,
                "model": model_name,
                "streaming": False,
                "duration_ms": round((t_end - t_start) * 1000),
                "time_to_first_token_ms": None,
                "prompt_tokens": usage_data.get("prompt_tokens") or usage_data.get("input_tokens"),
                "completion_tokens": usage_data.get("completion_tokens") or usage_data.get("output_tokens"),
                "total_tokens": usage_data.get("total_tokens"),
                "raw_usage": usage_data if usage_data else None,
            })


def main():
    parser = argparse.ArgumentParser(description="Inference logging proxy")
    parser.add_argument("--listen-port", type=int, default=11500)
    parser.add_argument("--upstream", required=True,
                        help="Upstream URL (e.g. http://localhost:11434)")
    parser.add_argument("--metrics-file", required=True,
                        help="Path to inference-metrics.jsonl")
    parser.add_argument("--task-name-file", default="",
                        help="File containing current task name")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.listen_port), ProxyHandler)
    server.upstream_base = args.upstream
    server.metrics_file = args.metrics_file
    server.task_name_file = args.task_name_file
    server.metrics_lock = threading.Lock()

    print(f"Inference proxy listening on 127.0.0.1:{args.listen_port} -> {args.upstream}",
          file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
