# keploy-ci-go-build: Go + MinGW cross-compilers + MinIO client
# Used by: go-test.yml download-and-build, prepare-and-run.yml build-and-upload-keploy
FROM public.ecr.aws/docker/library/golang:1.25-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gcc-mingw-w64-x86-64 \
        g++-mingw-w64-x86-64 \
        jq \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    # Install MinIO client
    curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/mc" -o /usr/local/bin/mc; \
    chmod +x /usr/local/bin/mc
