# keploy-ci-playwright: keploy-ci-node + Playwright Chromium + mongoDB tools
# Eliminates per-run downloads of ~500MB (Playwright browser + system deps + mongo tools).
# Used by: playwright.yml, playwright-e2e.yml (Woodpecker CI)
FROM ghcr.io/keploy/keploy-ci:node-1.2.13

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
RUN set -eux; \
    # Install Playwright and Chromium with system deps
    npm install -g playwright@${PLAYWRIGHT_VERSION}; \
    npx playwright install --with-deps chromium; \
    \
    # Install MongoDB Database Tools from the official repo
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
        gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg; \
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" \
        > /etc/apt/sources.list.d/mongodb-org-7.0.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends mongodb-database-tools; \
    \
    # Install zip (needed for report archiving)
    apt-get install -y --no-install-recommends zip; \
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
