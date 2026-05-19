# CLAUDE.md — Conventions for this repo

This file is read by Claude Code at the start of every session in this repository.
Follow these conventions without being asked.


## Repository layout

- **Site content** lives in `docs/`. This is the MkDocs source; everything here
  compiles to the GitHub Pages site.
- **Technical artifacts** live at the repo root in named directories:
  - `scenarios/` — Kubernetes scenario manifests + setup/teardown scripts
  - `benchmark/` — benchmark runner and collected data
  - `otel-demo/` — ClickHouse + OpenTelemetry demo (Posts 2 and 8)
  - `watcher-example/` — reference watcher implementation (Post 5)
  - `skills/` — packaged Claude Code Skills (e.g., k8s/SKILL.md)
  - `shared/` — cluster bootstrap scripts and Ollama configuration

## Branching

- `main` — stable, always deployable. Every push triggers the GitHub Pages deploy.
- `drafts/0N-slug` — work-in-progress branches for unreleased posts.
  Example: `drafts/03-air-gapped`. Open a PR to `main` only when the post is
  ready to publish.
- Never commit directly to `main` for new posts — use a draft branch + PR.

## Scenario conventions

Every scenario directory under `scenarios/` must contain:
- `manifests/` — the scenario Kubernetes manifests
- `README.md` — problem description, expected error, and fix summary
- `setup.sh` — idempotent script to apply the scenario state to a cluster

## Benchmark conventions

- Every benchmark run must commit raw results as JSONL to `benchmark/data/raw/`.
- Filename format: `YYYYMMDD-T-<model-slug>-<scenario>.jsonl`
- Never post-process in place; transformations go in `benchmark/analysis/`.

## Security

- Never commit API keys, tokens, credentials, or model weights.
- Never embed secrets in CLAUDE.md, mkdocs.yml, or any tracked config file.
- If a scenario legitimately needs a secret at runtime, document it in the
  scenario README and load it from environment variables.

## MkDocs / docs conventions

- All docs pages must have a single top-level H1 matching the nav title.
- Use MkDocs Material admonitions (`!!! note`, `!!! warning`, etc.) for callouts.
- Code blocks must specify a language for syntax highlighting.
- Internal links use relative paths (e.g., `../reference/benchmark-methodology.md`).

## Commit style

- Use conventional commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`.
- Scope is optional but encouraged for large repos: `docs(handbook):`, `feat(scenarios):`.
- Keep the subject line under 72 characters.

## Skills

Three operational skills live in `.claude/skills/`. Load them at the start
of any investigation session:

- **clickhouse** — OTel log/trace/metric queries. Use `clickhouse client`
  (two words, not hyphenated). Tables: `otel_logs`, `otel_traces`,
  `otel_metrics_gauge`, `otel_metrics_sum`, `otel_metrics_histogram`.
- **k8s** — Kubernetes diagnosis and remediation via kubectl.
- **gh** — GitHub CLI for commits, issues, and PRs.
