# keploy-ci-playwright: keploy-ci-node + Playwright system deps + MongoDB tools
# Pre-installs OS-level libraries needed by Chromium (fonts, libatk, libnss, etc.),
# MongoDB Database Tools, and CI utilities. Node modules and the Playwright browser
# binary are cached via MinIO at pipeline runtime.
# Used by: playwright.yml, playwright-e2e.yml (Woodpecker CI)
FROM ghcr.io/keploy/keploy-ci:node-1.2.15

ARG MONGO_TOOLS_VERSION=100.10.0

RUN set -eux; \
    # ── Playwright system dependencies (OS packages only, NOT the browser binary).
    # These are the ~200 apt packages (fonts, libatk, libcups, libnss, etc.)
    # that Chromium needs at runtime. Rarely change.
    npx playwright install-deps chromium; \
    \
    # ── MongoDB Database Tools (mongorestore, mongodump, etc.)
    # Downloaded as .deb because the MongoDB apt repo GPG key uses SHA1
    # which Debian trixie rejects since 2026-02-01.
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
    # ── CI utilities
    apt-get install -y --no-install-recommends zip zstd; \
    \
    # ── Cleanup
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /root/.npm/_cacache; \
    \
    # ── Verify
    mongorestore --version; \
    echo "Static dependencies installed successfully"

# Cache helper script for MinIO-backed npm/Go caching.
COPY minio-cache /usr/local/bin/minio-cache
RUN chmod +x /usr/local/bin/minio-cache
