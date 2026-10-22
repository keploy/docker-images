# keploy-ci-golint: Go + golangci-lint pre-installed, with the C headers and
# the other Linux architecture's cross compiler that enterprise's cgo typecheck
# needs (see below).
# Used by: golangci-lint.yml
# By digest: golang:1.27-bookworm floats to each new patch, and this image's Go
# must be the patch every CI image ships (keploy-ci/Dockerfile's GO_VERSION).
FROM golang:1.27.3-bookworm@sha256:972b4110ba0f47539a975c31e52c64765e1ff19f2d74469ae4a595c6676e80a5

# The C toolchain pieces enterprise's lint needs for its cgo, which the
# typecheck runs (cgo code is type-checked from what cgo generates):
#
#  - the headers the `gui` build tag needs: the agent UI (cmd/agent/build,
#    fyne) links OpenGL through go-gl/gl (`pkg-config: gl`) and X11 through
#    go-gl/glfw, and without them its typecheck stops at
#    "Package 'gl', required by 'virtual:world', not found", failing the
#    whole run;
#  - a C cross compiler, with its libc headers, for the OTHER Linux
#    architecture, so one runner lints linux/amd64 and linux/arm64 alike.
#    pg_query_go embeds the Postgres parser in C, so a linux typecheck is
#    cgo, and cgo needs a compiler for the target. Both triplet names exist
#    on either image (the native one is gcc itself), so the same command
#    works on any runner: `CGO_ENABLED=1 GOARCH=arm64
#    CC=aarch64-linux-gnu-gcc`, or `CGO_ENABLED=1 GOARCH=amd64
#    CC=x86_64-linux-gnu-gcc` (a cross build leaves cgo off unless
#    CGO_ENABLED says otherwise).
#
# Above the ARG, so a golangci-lint bump does not reinstall all of this. Ends
# by compiling, with the cross compiler, what cgo and the gui tag include (libc
# and the GL/X11 headers) and linking it, and by resolving the GL/X11 pkg-config
# modules, so a renamed package or a broken toolchain fails here, not in a lint
# lane.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) cross="gcc-aarch64-linux-gnu libc6-dev-arm64-cross"; cc=aarch64-linux-gnu-gcc ;; \
        arm64) cross="gcc-x86-64-linux-gnu libc6-dev-amd64-cross"; cc=x86_64-linux-gnu-gcc ;; \
        *) echo "no cross compiler chosen for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        jq \
        libgl1-mesa-dev \
        libx11-dev \
        libxcursor-dev \
        libxi-dev \
        libxinerama-dev \
        libxrandr-dev \
        libxxf86vm-dev \
        $cross; \
    rm -rf /var/lib/apt/lists/*; \
    printf '#include <stdlib.h>\n#include <string.h>\n#include <GL/gl.h>\n#include <X11/Xlib.h>\nint main(void) { return 0; }\n' \
        | "$cc" -x c - -o /tmp/cross-probe; \
    rm -f /tmp/cross-probe; \
    pkg-config --exists gl x11 xcursor xi xinerama xrandr xxf86vm

# v2.14.0: the first that reads go1.27.2's export data. v2.13.1 and v2.13.2,
# under go1.27.2, fail every package's typecheck on its stdlib imports
# ("could not import cmp (... export data version 5 is greater than maximum
# supported version 4)"), and golint-1.2.46 shipped v2.13.2 on go1.27.2.
ARG GOLANGCI_LINT_VERSION=v2.14.0

# golangci-lint is installed by hand rather than by piping upstream's
# install.sh, which cannot install any version we are able to use here.
#
# From v2.13.0 the release publishes an SBOM alongside each archive, named
# "<tarball>.sbom.json", so the checksums file carries two lines whose names
# both CONTAIN the tarball name. install.sh looks the checksum up with an
# unanchored grep:
#
#     want=$(grep "${BASENAME}" "${checksums}" | tr '\t' ' ' | cut -d ' ' -f 1)
#
# which matches both lines, leaves $want holding two hashes, and fails the
# verify every time with a correctly downloaded archive:
#
#     err hash_sha256_verify checksum for '...-linux-amd64.tar.gz' did not verify
#
# v2.13.0 is also the first release built with Go 1.27, and golangci-lint
# refuses to run when its build Go is older than the module's target, so every
# version new enough for a `go 1.27.0` module hits that bug. Matching the
# checksum line on the EXACT filename avoids it and keeps verification intact.
#
# Ends by linting a module that imports the stdlib, with this image's Go, so a
# golangci-lint that cannot read this Go's export data fails here, not in a
# lint lane: `golangci-lint --version`, the check before, passed v2.13.2 on
# go1.27.2, which then could not typecheck a single package. Its caches go
# with the probe, and the telemetry counters its go writes.
RUN set -eux; \
    version="${GOLANGCI_LINT_VERSION#v}"; \
    arch="$(dpkg --print-architecture)"; \
    name="golangci-lint-${version}-linux-${arch}"; \
    url="https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}"; \
    curl -sSfL --retry 5 --retry-delay 2 --retry-all-errors "${url}/${name}.tar.gz" -o /tmp/golangci-lint.tar.gz; \
    curl -sSfL --retry 5 --retry-delay 2 --retry-all-errors "${url}/golangci-lint-${version}-checksums.txt" -o /tmp/golangci-lint-checksums.txt; \
    want="$(awk -v f="${name}.tar.gz" '$2 == f { print $1 }' /tmp/golangci-lint-checksums.txt)"; \
    test -n "${want}"; \
    echo "${want}  /tmp/golangci-lint.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/golangci-lint.tar.gz -C /tmp; \
    install "/tmp/${name}/golangci-lint" /usr/local/bin/golangci-lint; \
    rm -rf /tmp/golangci-lint.tar.gz /tmp/golangci-lint-checksums.txt "/tmp/${name}"; \
    golangci-lint --version; \
    mkdir -p /tmp/lint-probe; \
    printf 'module probe\n\ngo 1.27.0\n' >/tmp/lint-probe/go.mod; \
    printf 'package probe\n\nimport (\n\t"cmp"\n\t"fmt"\n\t"slices"\n)\n\n// Largest is the largest of xs.\nfunc Largest(xs []int) int { return slices.MaxFunc(xs, cmp.Compare[int]) }\n\n// Show formats x.\nfunc Show(x int) string { return fmt.Sprint(x) }\n' >/tmp/lint-probe/probe.go; \
    cd /tmp/lint-probe; \
    GOCACHE=/tmp/lint-probe-cache GOLANGCI_LINT_CACHE=/tmp/lint-probe-lintcache GOFLAGS=-mod=mod golangci-lint run ./...; \
    cd /; \
    rm -rf /tmp/lint-probe /tmp/lint-probe-cache /tmp/lint-probe-lintcache /root/.config/go
