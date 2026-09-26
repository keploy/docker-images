# keploy-ci-lighthouse: keploy-ci-node + Chromium + Lighthouse CI
# Used by: landing lighthouse.yml (Lighthouse score comparison on PRs)
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
# NOTE: node-1.2.32 is itself still Go 1.26 — the node tags only gain Go 1.27
# from the first release built with this change. So a bare local `docker build`
# of this image reproduces the old behaviour until then; CI always overrides
# BASE_TAG with the version being published.
ARG BASE_TAG=node-1.2.32
FROM ghcr.io/keploy/keploy-ci:${BASE_TAG}
# Ship the current cache helper and its S3 client rather than inherit them: a
# base node tag older than this release carries a minio-cache that speaks
# through MinIO's mc (gone from these images) and, older still, one that
# appended a MinIO ILM rule on every save.
COPY minio-cache /usr/local/bin/minio-cache
COPY s3.sh /usr/local/lib/keploy-ci/s3.sh
RUN chmod +x /usr/local/bin/minio-cache /usr/local/lib/keploy-ci/s3.sh

ENV DEBIAN_FRONTEND=noninteractive

# Install Chromium and all its runtime dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        chromium \
        fonts-dejavu-core \
        fonts-dejavu-mono; \
    rm -rf /var/lib/apt/lists/*; \
    chromium --version

# Pre-install Lighthouse CI globally
RUN npm install -g @lhci/cli && lhci --version

# Set Chrome path for Lighthouse
ENV CHROME_PATH=/usr/bin/chromium
