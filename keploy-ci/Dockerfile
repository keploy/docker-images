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
COPY start-docker /usr/local/bin/start-docker
RUN chmod +x /usr/local/bin/start-docker

# Default shell for CI
SHELL ["/bin/sh", "-lc"]
