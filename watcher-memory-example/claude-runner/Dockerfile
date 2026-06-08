FROM node:20-slim

# Install kubectl, gh, git
RUN apt-get update && \
    apt-get install -y --no-install-recommends git curl ca-certificates gettext-base && \
    # kubectl
    curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && \
    # gh
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Non-root user
RUN useradd --create-home --shell /bin/bash runner

# Create memory-store fallback (overridden by volume mount at runtime)
RUN mkdir -p /memory-store/incidents && chown -R runner:runner /memory-store

# Copy skills from repo root at build time
# Build context is repo root (set in docker-compose.yml), so paths are relative to it
COPY --chown=runner:runner skills /home/runner/.claude/skills

# Copy invoke script and workspace CLAUDE.md
COPY watcher-memory-example/claude-runner/invoke.sh /usr/local/bin/invoke.sh
COPY watcher-memory-example/claude-runner/workspace-claude.md /usr/local/bin/workspace-claude.md
RUN chmod +x /usr/local/bin/invoke.sh

ENV KUBECONFIG=/home/runner/.kube/config

USER runner
WORKDIR /home/runner

ENTRYPOINT ["/usr/local/bin/invoke.sh"]
