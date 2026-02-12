# keploy-ci-timefreeze: Debian + clang-14 + cross-compilers for building timefreeze .so files
# Used by: prepare-and-run.yml  build-timefreeze step
FROM public.ecr.aws/docker/library/debian:bookworm-slim

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        clang-14 \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
    ; \
    rm -rf /var/lib/apt/lists/*
