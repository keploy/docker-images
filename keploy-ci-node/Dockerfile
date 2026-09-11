# keploy-ci-node: keploy-ci + Node.js 24 + minio-cache (DinD + eBPF capable)
# Used by: node-linux.yml, node-docker-linux.yml, enterprise-ui node-ci.yml
# The base tag is a BUILD ARG, not a frozen literal.
#
# Every derived image here used to hard-code `FROM ghcr.io/keploy/keploy-ci:<tag>`,
# and nothing ever moved those literals: publish.yml rebuilds all variants on each
# release, but each one kept building on whatever base tag was current the day it
# was written. keploy-ci-node sat on 1.2.23 for nine releases, so when the base
# moved to Go 1.27 (#21) node — and everything FROM node, including playwright —
# silently stayed on Go 1.26. Downstream repos then built go-1.27 modules in a
# go-1.26 image and, because these images default GOTOOLCHAIN=auto, pulled a
# ~325MB toolchain at pipeline time instead of failing.
#
# publish.yml now passes BASE_TAG=<version being published>, so a derived image
# always sits on the base from the SAME release. The default below is only for a
# bare `docker build` outside CI.
ARG BASE_TAG=1.2.32
FROM ghcr.io/keploy/keploy-ci:${BASE_TAG}
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -; \
    apt-get install -y --no-install-recommends nodejs zstd; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version

# Cache helper script for MinIO-backed caching (zstd compressed).
COPY minio-cache /usr/local/bin/minio-cache
RUN chmod +x /usr/local/bin/minio-cache
