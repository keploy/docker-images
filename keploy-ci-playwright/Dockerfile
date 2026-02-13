# keploy-ci-playwright: keploy-ci-node + Playwright Chromium + mongoDB tools
# Eliminates per-run downloads of ~500MB (Playwright browser + system deps + mongo tools).
# Used by: playwright.yml, playwright-e2e.yml (Woodpecker CI)
FROM ghcr.io/keploy/keploy-ci:node-1.2.15

# Pin Playwright to a known version so the pre-installed browser stays valid.
# Bump this ARG (and rebuild the image) whenever enterprise-ui updates its
# @playwright/test dependency.
ARG PLAYWRIGHT_VERSION=1.58.2

# 1. Install Playwright + Chromium browser + all required system libraries.
#    `npx playwright install --with-deps chromium` fetches the browser binary
#    AND installs OS packages (libatk, fonts, etc.) needed to run headless Chrome.
# 2. Install MongoDB Database Tools (mongorestore, mongodump, etc.) so we can
#    restore test fixtures without `apt-get install` inside a mongo container.
# 3. Clean up caches to keep the image small.
ARG MONGO_TOOLS_VERSION=100.10.0
ARG MONGO_TOOLS_DEB_RELEASE=1

RUN set -eux; \
    # Install Playwright and Chromium with system deps
    npm install -g playwright@${PLAYWRIGHT_VERSION}; \
    npx playwright install --with-deps chromium; \
    \
    # Install MongoDB Database Tools directly from .deb package.
    # (The MongoDB apt repo GPG key uses SHA1 which Debian trixie rejects.)
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
        amd64) MONGO_ARCH="x86_64" ;; \
        arm64) MONGO_ARCH="aarch64" ;; \
        *) echo "Unsupported arch: $ARCH"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/mongodb-database-tools.deb \
        "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian12-${MONGO_ARCH}-${MONGO_TOOLS_VERSION}.deb"; \
    dpkg -i /tmp/mongodb-database-tools.deb || apt-get install -yf --no-install-recommends; \
    rm -f /tmp/mongodb-database-tools.deb; \
    \
    # Install zip (report archiving) and zstd (cache compression)
    apt-get install -y --no-install-recommends zip zstd; \
    \
    # Cleanup
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /root/.npm/_cacache; \
    \
    # Verify installs
    npx playwright --version; \
    mongorestore --version; \
    echo "Playwright Chromium + MongoDB tools installed successfully"

# Cache helper script for MinIO-backed npm/Go caching.
COPY minio-cache /usr/local/bin/minio-cache
RUN chmod +x /usr/local/bin/minio-cache
