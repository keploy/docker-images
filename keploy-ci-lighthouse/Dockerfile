# keploy-ci-lighthouse: keploy-ci-node + Chromium + Lighthouse CI
# Used by: landing lighthouse.yml (Lighthouse score comparison on PRs)
FROM ghcr.io/keploy/keploy-ci:node-1.2.17

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
