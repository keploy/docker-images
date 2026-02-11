# keploy-ci: Go + Docker daemon + common CI dependencies (Debian-based)
# Base image provides: dockerd, docker CLI, buildx, containerd, runc
FROM debian:trixie-slim

ARG GO_VERSION=1.25.7
# Keep Docker "major.minor" aligned with the latest stable release.
ARG DOCKER_MAJOR_MINOR=29.1
# Provided automatically by BuildKit/buildx; fallback to dpkg when unset.
ARG TARGETARCH

# Install common CI utilities and build dependencies for CGO builds.
RUN set -eux; \
  ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
  apt-get update; \
  EXTRA_PKGS=""; \
  if [ "$ARCH" = "amd64" ]; then \
  EXTRA_PKGS="gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64"; \
  fi; \
  apt-get install -y --no-install-recommends \
  awscli \
  bash \
  ca-certificates \
  coreutils \
  curl \
  git \
  gnupg \
  iproute2 \
  iptables \
  jq \
  linux-headers-"$ARCH" \
  lsof \
  net-tools \
  netcat-openbsd \
  nodejs \
  npm \
  openssh-client \
  openssl \
  passwd \
  pkg-config \
  procps \
  psmisc \
  python3 \
  python3-pip \
  python3-venv \
  socat \
  sudo \
  tar \
  tree \
  uidmap \
  util-linux \
  xz-utils \
  build-essential \
  default-jdk \
  gcc \
  g++-aarch64-linux-gnu \
  gcc-aarch64-linux-gnu \
  libc-dev \
  libgl1-mesa-dev \
  maven \
  libx11-dev \
  libx11-xcb-dev \
  libxcursor-dev \
  libxi-dev \
  libxinerama-dev \
  libxrandr-dev \
  libxxf86vm-dev \
  $EXTRA_PKGS; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/*

# Install clang-14 from Debian Bookworm (not available in Trixie).
RUN set -eux; \
  echo "deb http://deb.debian.org/debian bookworm main" > /etc/apt/sources.list.d/bookworm.list; \
  printf '%s\n' \
  'Package: *' \
  'Pin: release n=bookworm' \
  'Pin-Priority: 100' \
  '' \
  'Package: clang-14 lib*clang*14* libllvm14* llvm-14*' \
  'Pin: release n=bookworm' \
  'Pin-Priority: 500' \
  > /etc/apt/preferences.d/clang-14; \
  apt-get update; \
  apt-get install -y --no-install-recommends clang-14; \
  rm -f /etc/apt/sources.list.d/bookworm.list /etc/apt/preferences.d/clang-14; \
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

# Install Go and MinIO client (mc).
RUN set -eux; \
  ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
  case "$ARCH" in \
  amd64|arm64) ;; \
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
  esac; \
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz; \
  rm -rf /usr/local/go; \
  tar -C /usr/local -xzf /tmp/go.tgz; \
  rm -f /tmp/go.tgz; \
  curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" -o /usr/local/bin/mc; \
  chmod +x /usr/local/bin/mc

ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"
ENV GOPATH="/root/go"

# Install Go-based CI tools: goreleaser and fyne.
# These are commonly used in release pipelines and pre-installing saves ~2-3 min per run.
ARG GORELEASER_VERSION=2.13.3
ARG FYNE_VERSION=latest
RUN set -eux; \
  go install github.com/goreleaser/goreleaser/v2@v${GORELEASER_VERSION}; \
  go install fyne.io/tools/cmd/fyne@${FYNE_VERSION}; \
  # Verify installations
  goreleaser --version; \
  fyne version; \
  # Clean up Go build cache to reduce image size
  go clean -cache -modcache || true

# Helper script to start dockerd inside the step container.
# Supports optional DOCKERD_FLAGS (for example: "--registry-mirror=http://x:5000").
COPY start-docker /usr/local/bin/start-docker
RUN chmod +x /usr/local/bin/start-docker

# Optional but common for DinD.
VOLUME ["/var/lib/docker"]

# Default shell for CI.
SHELL ["/bin/sh", "-lc"]
