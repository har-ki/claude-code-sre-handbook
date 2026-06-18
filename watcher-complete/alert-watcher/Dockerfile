FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates jq && \
    rm -rf /var/lib/apt/lists/*

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
      https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# Docker CLI (for spawning claude-runner containers)
RUN curl -fsSL https://download.docker.com/linux/static/stable/$(uname -m)/docker-27.5.1.tgz \
    | tar xz --strip-components=1 -C /usr/local/bin docker/docker

RUN git config --global user.email "watcher@claude-code-sre-handbook" && \
    git config --global user.name "Alert Watcher"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py store.py config.yaml ./

CMD ["python", "main.py"]
