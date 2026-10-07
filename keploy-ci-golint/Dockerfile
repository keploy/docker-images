# keploy-ci-golint: Go + golangci-lint pre-installed, with the C headers and
# the other Linux architecture's cross compiler that enterprise's cgo typecheck
# needs (see below).
# Used by: golangci-lint.yml
FROM golang:1.27-bookworm

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

ARG GOLANGCI_LINT_VERSION=v2.13.2

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
    golangci-lint --version
