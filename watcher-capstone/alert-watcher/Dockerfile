FROM python:3.11-slim

# Install gh CLI, git, and Docker CLI
RUN apt-get update && \
    apt-get install -y --no-install-recommends git curl ca-certificates && \
    # gh CLI
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    # Docker CLI (for spawning runner containers)
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh docker-ce-cli && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git config --global user.email "watcher@claude-sre" && \
    git config --global user.name "SRE Watcher"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config.yaml .
COPY main.py .
COPY store.py .

# Run as root for Docker socket access
CMD ["python", "main.py"]
