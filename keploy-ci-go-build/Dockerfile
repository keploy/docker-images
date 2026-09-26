# keploy-ci-go-build: Go + MinGW cross-compilers
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
    rm -rf /var/lib/apt/lists/*
# No MinIO client: the CI object store is SeaweedFS, reached through the repos'
# own .ci/scripts/s3.sh over the curl in golang:*-bookworm (7.88.1, which s3.sh
# supports; see keploy-ci/Dockerfile).
