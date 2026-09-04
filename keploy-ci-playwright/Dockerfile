# keploy-ci-playwright: keploy-ci-node + Playwright system deps + browsers + MongoDB tools
# Pre-installs the OS-level libraries Chromium needs (fonts, libatk, libnss, etc.),
# THE CHROMIUM BROWSER ITSELF, MongoDB Database Tools, and CI utilities.
# Used by: playwright.yml, playwright-e2e.yml (Woodpecker CI)
FROM ghcr.io/keploy/keploy-ci:node-1.2.25

ARG MONGO_TOOLS_VERSION=100.10.0

# Must track the `@playwright/test` version pinned in the consuming repo's
# package-lock.json (enterprise-ui: 1.62.1). Playwright resolves a browser build
# by revision, so a mismatch means the baked browser is ignored — see the note on
# the install step below for what happens then.
#
# 1.57.0 -> 1.62.1 moves the chromium revision from 1200 to 1234. Measured in
# enterprise-ui while the two were out of step: the baked directory is non-empty
# but holds 1200, so the consumer's restore guard reports "already present",
# skips the MinIO cache, and `npx playwright install` then pulls ~300 MiB from
# Microsoft's CDN (Chrome 184.3 MiB + Headless Shell 114.7 MiB) — about five
# minutes, on every one of ~16 lanes, on the critical path.
ARG PLAYWRIGHT_VERSION=1.62.1

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
    # Installed to the default location for the image's user (root, HOME unset ->
    # /root/.cache/ms-playwright). That path matters: it is what enterprise-ui's
    # .ci/scripts/restore-playwright-cache.sh and the install guard in
    # playwright-setup.sh both probe, so a baked image short-circuits BOTH the
    # MinIO restore and `npx playwright install` with no change needed there.
    # Do not set PLAYWRIGHT_BROWSERS_PATH — that would move the browsers away
    # from where those probes look and silently reintroduce the download.
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
    curl -fsSL -o /tmp/mongodb-database-tools.deb \
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
    # Both halves, named. A lane needs the full browser AND the headless shell,
    # and "non-empty" is satisfied by either one alone.
    test -n "$(find /root/.cache/ms-playwright -maxdepth 1 -name 'chromium-*' -print -quit)"; \
    test -n "$(find /root/.cache/ms-playwright -maxdepth 1 -name 'chromium_headless_shell-*' -print -quit)"; \
    ls -1 /root/.cache/ms-playwright; \
    find /root/.cache/ms-playwright -name 'headless_shell' -o -name 'chrome' | head -5; \
    du -sh /root/.cache/ms-playwright; \
    # Record WHAT was baked, so a consumer can tell "browsers are present" from
    # "the browsers this lockfile actually wants are present" — the distinction
    # that costs ~300 MiB per lane when it is guessed instead of checked. The
    # probes downstream only test that the directory is non-empty, which a stale
    # revision satisfies; this file is what lets them do better without having to
    # know how Playwright lays the directory out.
    basename "$(find /root/.cache/ms-playwright -maxdepth 1 -name 'chromium-*' -print -quit)" \
      | sed 's/^chromium-//' > /root/.cache/ms-playwright/.baked-chromium-revision; \
    echo "${PLAYWRIGHT_VERSION}" > /root/.cache/ms-playwright/.baked-playwright-version; \
    echo "Baked Playwright ${PLAYWRIGHT_VERSION}, chromium revision $(cat /root/.cache/ms-playwright/.baked-chromium-revision)"

# Cache helper script for MinIO-backed npm/Go caching.
COPY minio-cache /usr/local/bin/minio-cache
RUN chmod +x /usr/local/bin/minio-cache
