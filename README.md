# The Claude Code SRE Handbook

A technical blog series exploring how SREs can use Claude Code as an on-call AI pair programmer.

## Site

The handbook is published at **https://har-ki.github.io/claude-code-sre-handbook/**.

## Structure

| Directory | Purpose |
|-----------|---------|
| `docs/` | MkDocs source — all markdown content |
| `scenarios/` | Kubernetes broken manifests + setup scripts |
| `benchmark/` | Benchmark runner and raw JSONL data |
| `otel-demo/` | ClickHouse + OTel demo (Posts 2 and 8) |
| `watcher-example/` | Reference watcher implementation (Post 5) |
| `skills/` | Packaged Claude Code Skills (e.g., k8s/SKILL.md) |
| `shared/` | Cluster bootstrap scripts and Ollama config |

## Local development

```bash
pip install mkdocs-material
mkdocs serve
```

## License

The Unlicense (public domain)
