# keploy-ci-playwright: keploy-ci-node + Playwright system deps + browsers + MongoDB tools
# Pre-installs the OS-level libraries Chromium needs (fonts, libatk, libnss, etc.),
# THE CHROMIUM BROWSER ITSELF, MongoDB Database Tools, and CI utilities.
# Used by: playwright.yml, playwright-e2e.yml (Woodpecker CI)
FROM ghcr.io/keploy/keploy-ci:node-1.2.25

ARG MONGO_TOOLS_VERSION=100.10.0

# Must track the `@playwright/test` version pinned in the consuming repo's
# package-lock.json (enterprise-ui: 1.57.0). Playwright resolves a browser build
# by revision, so a mismatch means the baked browser is ignored — see the note on
# the install step below for what happens then.
ARG PLAYWRIGHT_VERSION=1.57.0

RUN set -eux; \
    # ── Playwright system dependencies (OS packages only).
    # These are the ~200 apt packages (fonts, libatk, libcups, libnss, etc.)
    # that Chromium needs at runtime. Rarely change.
    npx --yes playwright@${PLAYWRIGHT_VERSION} install-deps chromium; \
    \
    # ── The Chromium binary itself. BAKED, not fetched at pipeline time.
    #
    # This image used to ship the OS deps but deliberately NOT the browser, and
    # left every lane to pull ~170 MB from MinIO on every run. Measured in
    # enterprise-ui: up to 16 lanes fan out at once and all of them hit the same
    # MinIO host, which also serves the build artifact and the docker image cache
    # and tops out around 200-250 MiB/s in aggregate. A transfer that runs at
    # ~100 MiB/s on a quiet host collapses to ~22 MiB/s once the fleet is in
    # flight, and 70% of the ~39.6 GiB a single pipeline pulls is static content
    # exactly like this that never changes between runs.
    #
    # Downloading it once here, at image build time, is strictly better: the
    # bytes ship in a layer the agents already cache, and pipeline-time cost goes
    # to zero.
    #
    # Installed to the default location for the image's user: root, with HOME set
    # to /root, so the browsers land in /root/.cache/ms-playwright. That path
    # matters — it is what enterprise-ui's .ci/scripts/restore-playwright-cache.sh
    # probes, so a baked image short-circuits the MinIO restore with no change
    # needed there.
    #
    # It does NOT skip `npx playwright install`, and must not: that call is
    # deliberately unguarded on the consumer side. Playwright resolves a browser
    # by revision, so after a package-lock bump this directory is non-empty but
    # holds the WRONG build — a guard keyed on "is the directory non-empty" would
    # then skip the install too and every lane would die at "Executable doesn't
    # exist at .../chromium-<rev>". Letting the install run makes it a no-op when
    # the revision matches and a self-heal when it does not.
    #
    # Do not set PLAYWRIGHT_BROWSERS_PATH — that would move the browsers away
    # from where the restore probe looks and silently reintroduce the download.
    #
    # If the consuming repo bumps @playwright/test past PLAYWRIGHT_VERSION above,
    # nothing breaks: the revision will not match, and the runtime path falls back
    # to the MinIO cache and then to `npx playwright install`. That is a slow
    # pipeline, not a broken one — but it is the signal to rebuild this image.
    npx --yes playwright@${PLAYWRIGHT_VERSION} install chromium; \
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
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /tmp/mongodb-database-tools.deb \
        "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian12-${MONGO_ARCH}-${MONGO_TOOLS_VERSION}.deb"; \
    dpkg -i /tmp/mongodb-database-tools.deb || apt-get install -yf --no-install-recommends; \
    rm -f /tmp/mongodb-database-tools.deb; \
    \
    # ── CI utilities
    apt-get install -y --no-install-recommends zip zstd ffmpeg; \
    \
    # ── Cleanup
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /root/.npm/_cacache; \
    \
    # ── Verify
    mongorestore --version; \
    # The browsers are the whole point of this image now, and an empty directory
    # would ship silently: every consumer's probe checks only that the path is
    # non-empty, so a half-installed tree reads as "baked" and the tests then
    # fail far downstream with a missing-executable error. Assert here instead.
    test -d /root/.cache/ms-playwright; \
    test -n "$(ls -A /root/.cache/ms-playwright)"; \
    ls -1 /root/.cache/ms-playwright; \
    find /root/.cache/ms-playwright -name 'headless_shell' -o -name 'chrome' | head -5; \
    du -sh /root/.cache/ms-playwright; \
    echo "Static dependencies + Chromium ${PLAYWRIGHT_VERSION} baked successfully"

# Cache helper script for MinIO-backed npm/Go caching.
COPY minio-cache /usr/local/bin/minio-cache
RUN chmod +x /usr/local/bin/minio-cache
