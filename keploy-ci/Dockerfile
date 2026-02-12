# keploy-ci: Go + Docker daemon + common CI deps (Debian-based)
# Base includes: dockerd, docker CLI, buildx, containerd, runc
#
# CGO is only needed for Windows cross-compilation, which is handled
# by the keploy-ci-go-build image (with MinGW). This image builds
# Linux binaries with CGO_ENABLED=0.
FROM public.ecr.aws/docker/library/debian:trixie-slim

ARG GO_VERSION=1.25.7
# Keep Docker "major.minor" aligned with the latest stable release.
ARG DOCKER_MAJOR_MINOR=29.1
# Provided automatically by BuildKit/buildx; fallback to dpkg when unset.
ARG TARGETARCH

# Install common CI utilities (no build/CGO deps — Linux builds use CGO_ENABLED=0).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        git \
        gnupg \
        iproute2 \
        iptables \
        jq \
        lsof \
        net-tools \
        netcat-openbsd \
        openssh-client \
        openssl \
        passwd \
        procps \
        psmisc \
        python3 \
        socat \
        sudo \
        tar \
        uidmap \
        util-linux \
        xz-utils \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Install Docker Engine (dockerd + docker CLI + buildx + compose).
# Uses Docker's official Debian apt repository.
RUN set -eux; \
    ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    chmod a+r /etc/apt/keyrings/docker.gpg; \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    DOCKER_VERSION="$(apt-cache madison docker-ce | awk -v mm="$DOCKER_MAJOR_MINOR" '$3 ~ "^5:"mm"\\." {print $3; exit}')"; \
    if [ -z "$DOCKER_VERSION" ]; then \
        echo "ERROR: Docker Engine ${DOCKER_MAJOR_MINOR}.x not found in apt repo. Available docker-ce versions:"; \
        apt-cache madison docker-ce; \
        exit 1; \
    fi; \
    apt-get install -y --no-install-recommends \
        docker-ce="$DOCKER_VERSION" \
        docker-ce-cli="$DOCKER_VERSION" \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Install Go.
RUN set -eux; \
    ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$ARCH" in \
        amd64|arm64) ;; \
        *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz

# Install MinIO client (mc) — used for artifact storage in CI pipelines.
RUN set -eux; \
    ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" -o /usr/local/bin/mc; \
    chmod +x /usr/local/bin/mc

ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"
ENV GOPATH="/root/go"

# Helper script to start dockerd inside the step container.
# Supports optional DOCKERD_FLAGS (for example: "--registry-mirror=http://x:5000").
COPY start-docker /usr/local/bin/start-docker
RUN chmod +x /usr/local/bin/start-docker

# Optional but common for DinD.
VOLUME ["/var/lib/docker"]

# Default shell for CI.
SHELL ["/bin/sh", "-lc"]
