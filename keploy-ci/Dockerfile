# keploy-ci: Go + Docker daemon + common CI deps (Debian-based)
# Base includes: dockerd, docker CLI, buildx, containerd, runc
FROM debian:trixie-slim

ARG GO_VERSION=1.25.7
# Keep Docker "major.minor" aligned with the latest stable version
ARG DOCKER_MAJOR_MINOR=29.1

# Common CI utilities + build deps for CGO builds
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    tar \
    git \
    openssh-client \
    jq \
    openssl \
    socat \
    iproute2 \
    netcat-openbsd \
    sudo \
    build-essential \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    linux-headers-$(dpkg --print-architecture) \
    coreutils \
    util-linux \
    passwd \
    gnupg \
    xz-utils \
    iptables \
    uidmap \
    # Additional packages used in CI pipelines
    procps \
    lsof \
    tree \
    psmisc \
    net-tools \
    ; \
    rm -rf /var/lib/apt/lists/*

# Install clang-14 from Debian Bookworm (not available in Trixie)
RUN set -eux; \
    echo "deb http://deb.debian.org/debian bookworm main" > /etc/apt/sources.list.d/bookworm.list; \
    printf 'Package: *\nPin: release n=bookworm\nPin-Priority: 100\n\nPackage: clang-14 lib*clang*14* libllvm14* llvm-14*\nPin: release n=bookworm\nPin-Priority: 500\n' > /etc/apt/preferences.d/clang-14; \
    apt-get update; \
    apt-get install -y --no-install-recommends clang-14; \
    rm -f /etc/apt/sources.list.d/bookworm.list /etc/apt/preferences.d/clang-14; \
    rm -rf /var/lib/apt/lists/*

# Install Docker Engine (dockerd + docker CLI + buildx plugin + containerd)
# Uses Docker's official Debian apt repository.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    chmod a+r /etc/apt/keyrings/docker.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
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
    docker-compose-plugin \
    ; \
    rm -rf /var/lib/apt/lists/*

# Install Go
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
    amd64) GO_ARCH='linux-amd64' ;; \
    arm64) GO_ARCH='linux-arm64' ;; \
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.${GO_ARCH}.tar.gz" -o /tmp/go.tgz; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV CGO_ENABLED=1

# Install MinIO client (mc) - used heavily in CI pipelines for artifact storage
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
    amd64) MC_ARCH='linux-amd64' ;; \
    arm64) MC_ARCH='linux-arm64' ;; \
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    curl -fsSL "https://dl.min.io/client/mc/release/${MC_ARCH}/mc" -o /usr/local/bin/mc; \
    chmod +x /usr/local/bin/mc

# Helper to start dockerd inside the step container
# Supports optional DOCKERD_FLAGS env (e.g. "--registry-mirror=http://x:5000")
COPY start-docker /usr/local/bin/start-docker
RUN chmod +x /usr/local/bin/start-docker

# (Optional but common for DinD)
VOLUME ["/var/lib/docker"]

# Default shell for CI
SHELL ["/bin/sh", "-lc"]
