# keploy-ci-go-build: Go + MinGW cross-compilers + MinIO client
# Used by: go-test.yml download-and-build, prepare-and-run.yml build-and-upload-keploy
FROM golang:1.27-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gcc-mingw-w64-x86-64 \
        g++-mingw-w64-x86-64 \
        jq \
        # This image runs the gate build (prepare-and-run's
        # build-and-upload-keploy) and go-test's download-and-build, both of
        # which tar/compress the Go build cache and the shipped binary. gzip is
        # single-threaded and was measurably the slowest part of those steps.
        zstd \
        pigz \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    # Install MinIO client
    MC_RELEASE=RELEASE.2025-08-13T08-35-41Z; \
    curl -fsSL "https://github.com/minio/mc/releases/download/${MC_RELEASE}/mc.linux-amd64.${MC_RELEASE}" \
      -o /usr/local/bin/mc; \
    echo "01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891  /usr/local/bin/mc" | sha256sum -c -; \
    chmod +x /usr/local/bin/mc
