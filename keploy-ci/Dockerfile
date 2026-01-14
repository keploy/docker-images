# keploy-ci: Go + Docker daemon + common CI deps
# Base includes: dockerd, docker CLI, buildx, containerd, runc
FROM docker:26.1-dind

ARG GO_VERSION=1.25.0

# Common CI utilities + build deps for CGO builds
RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      tar \
      git \
      openssh-client \
      jq \
      socat \
      iproute2 \
      netcat-openbsd \
      sudo \
      build-base \
      linux-headers \
      coreutils \
      util-linux \
      shadow

# Install Go
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV CGO_ENABLED=1

# Helper to start dockerd inside the step container
# Supports optional DOCKERD_FLAGS env (e.g. "--registry-mirror=http://x:5000")
RUN printf '%s\n' '#!/usr/bin/env sh' \
  'set -eu' \
  '' \
  '# Make sure runtime dirs exist' \
  'mkdir -p /var/run /var/lib/docker' \
  '' \
  '# If already running, do nothing' \
  'if docker info >/dev/null 2>&1; then' \
  '  echo "Docker daemon already running"' \
  '  exit 0' \
  'fi' \
  '' \
  '# Default flags' \
  'FLAGS="${DOCKERD_FLAGS:-}"' \
  '' \
  '# Start dockerd in background' \
  'echo "Starting dockerd ${FLAGS} ..."' \
  'dockerd ${FLAGS} >/var/log/dockerd.log 2>&1 &' \
  '' \
  '# Wait until it is ready' \
  'for i in $(seq 1 60); do' \
  '  if docker info >/dev/null 2>&1; then' \
  '    echo "Docker daemon is ready"' \
  '    exit 0' \
  '  fi' \
  '  sleep 1' \
  'done' \
  '' \
  'echo "Docker daemon failed to start"' \
  'tail -n 200 /var/log/dockerd.log || true' \
  'exit 1' \
  > /usr/local/bin/start-docker \
  && chmod +x /usr/local/bin/start-docker

# Default shell for CI
SHELL ["/bin/sh", "-lc"]
