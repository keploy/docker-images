# keploy-ci-slim: Lightweight image for shell-only and MinIO CI steps
# Use this for: setup-auth, tag-guard, cleanup, download/upload artifacts, cosign, etc.
FROM public.ecr.aws/docker/library/alpine:3.21

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
    curl -fsSL "https://dl.min.io/client/mc/release/${MC_ARCH}/mc" -o /usr/local/bin/mc; \
    chmod +x /usr/local/bin/mc; \
    # Install cosign for Docker image signing
    COSIGN_VERSION=v2.5.2; \
    curl -sSfL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${COSIGN_ARCH}" \
      -o /usr/local/bin/cosign; \
    chmod +x /usr/local/bin/cosign

SHELL ["/bin/sh", "-lc"]
