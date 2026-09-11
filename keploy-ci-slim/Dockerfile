# keploy-ci-slim: Lightweight image for shell-only and MinIO CI steps
# Use this for: setup-auth, tag-guard, cleanup, download/upload artifacts, cosign, etc.
FROM alpine:3.21

# Common CI utilities (no Go, no Docker, no C compilers)
RUN set -eux; \
    apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    tar \
    # zstd and pigz are here for the CI artifact/cache paths: this image runs
    # the download-artifacts steps (~59 per enterprise PR pipeline), and the
    # objects they move are compressed. Single-threaded gzip is the slow part —
    # on a real 2.1 GB Go build cache, gzip took 14.6 s to compress and 7.8 s to
    # decompress where zstd -T0 took 1.3 s each way.
    zstd \
    pigz \
    git \
    openssh-client \
    jq \
    openssl \
    python3 \
    gnupg \
    coreutils \
    sudo \
    xz

# Install MinIO client (mc) — used for artifact upload/download in CI
RUN set -eux; \
    ARCH="$(uname -m)"; \
    case "$ARCH" in \
      x86_64)  MC_ARCH='linux-amd64'; COSIGN_ARCH='amd64' ;; \
      aarch64) MC_ARCH='linux-arm64'; COSIGN_ARCH='arm64' ;; \
      *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    case "$COSIGN_ARCH" in \
      amd64) MC_SHA=01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891 ;; \
      arm64) MC_SHA=14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c ;; \
    esac; \
    MC_RELEASE=RELEASE.2025-08-13T08-35-41Z; \
    curl -fsSL "https://github.com/minio/mc/releases/download/${MC_RELEASE}/mc.${MC_ARCH}.${MC_RELEASE}" \
      -o /usr/local/bin/mc; \
    echo "$MC_SHA  /usr/local/bin/mc" | sha256sum -c -; \
    chmod +x /usr/local/bin/mc; \
    # Install cosign for Docker image signing
    COSIGN_VERSION=v2.5.2; \
    curl -sSfL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${COSIGN_ARCH}" \
      -o /usr/local/bin/cosign; \
    chmod +x /usr/local/bin/cosign

SHELL ["/bin/sh", "-lc"]
