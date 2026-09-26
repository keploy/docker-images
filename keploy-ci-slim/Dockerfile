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

# No MinIO client: the CI object store is SeaweedFS, reached through the repos'
# own .ci/scripts/s3.sh over the curl above (see keploy-ci/Dockerfile).
# Install cosign for Docker image signing
RUN set -eux; \
    ARCH="$(uname -m)"; \
    case "$ARCH" in \
      x86_64)  COSIGN_ARCH='amd64' ;; \
      aarch64) COSIGN_ARCH='arm64' ;; \
      *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    COSIGN_VERSION=v2.5.2; \
    curl -sSfL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${COSIGN_ARCH}" \
      -o /usr/local/bin/cosign; \
    chmod +x /usr/local/bin/cosign

SHELL ["/bin/sh", "-lc"]
