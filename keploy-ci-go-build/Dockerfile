# keploy-ci-go-build: Go + MinGW cross-compilers + MinIO client
# Used by: go-test.yml download-and-build, prepare-and-run.yml build-and-upload-keploy
FROM public.ecr.aws/docker/library/golang:1.27-bookworm

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
    curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/mc" -o /usr/local/bin/mc; \
    chmod +x /usr/local/bin/mc
