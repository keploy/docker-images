# keploy-ci-go-build: Go + MinGW cross-compilers
# Used by: go-test.yml download-and-build, prepare-and-run.yml build-and-upload-keploy
# By digest: golang:1.27-bookworm floats to each new patch, and this image's Go
# must be the patch every CI image ships (keploy-ci/Dockerfile's GO_VERSION).
FROM golang:1.27.2-bookworm@sha256:5cf287a799e6b94384bad13d16b14904c531f51ba65792237e122ce42b392f61

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
