# keploy-ci-ebpf-objects: the toolchain keploy/ebpf's committed BPF objects are
# built with (the recipe in its compile.sh header: Ubuntu 22.04, clang-14 and
# llvm-14, libbpf-dev 0.5.0, the native and arm64 cross kernel and libc
# headers, Go 1.27.1, git), pinned, so that its objects-reproducible lane
# rebuilds every committed object without apt or a Go download.
# Used by: keploy/ebpf .woodpecker/objects-reproducible.yml, by digest.
#
# What is pinned, and how:
#  - the base: ubuntu:22.04 by its index digest;
#  - every package installed: the archive as it was at SNAPSHOT, read from
#    snapshot.ubuntu.com, so a rebuild resolves the same versions, dependencies
#    included, for as long as Canonical serves that snapshot (its stated aim:
#    at least the last two years). The recipe's own packages, and the
#    bootstrap's, are also named with =version: a snapshot that does not hold
#    exactly them fails the build here, instead of building an image that
#    builds other objects;
#  - Go: the release tarball, checked against its SHA-256 (go.dev/dl).
# Once Canonical stops serving SNAPSHOT this build fails. Moving SNAPSHOT may
# move the toolchain, so the result is a new toolchain: keploy/ebpf moves its
# lane to the new digest in a change of its own, which rebuilds and recommits
# its objects when they differ. Lanes pull a published ebpf-objects-* image by
# digest, and after that window it cannot be rebuilt: never prune one from GHCR.
#
# The recipe's versions are the ones the lane installed from the live archive
# on its last apt-based run (its dpkg-query -W line, 2026-10-19), with which
# the committed objects were rebuilt byte-for-byte; git's and the bootstrap's
# are the snapshot's.
#
# amd64 only: the lane is linux/amd64, and snapshot.ubuntu.com serves the
# primary archive, not ubuntu-ports (arm64), so an arm64 variant could not be
# pinned the same way.
FROM ubuntu@sha256:0a9887931b0e38af2e3487ed39e29436b0535c4f3f52e57745baaf79d1898956 AS go

ADD --checksum=sha256:63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445 \
    https://go.dev/dl/go1.27.1.linux-amd64.tar.gz /tmp/go.tgz
RUN tar -C /usr/local -xzf /tmp/go.tgz

FROM ubuntu@sha256:0a9887931b0e38af2e3487ed39e29436b0535c4f3f52e57745baaf79d1898956

ARG SNAPSHOT=20261019T000000Z

# The base has no CA bundle, so the first fetch, of ca-certificates and the
# openssl it depends on (libssl3 is the base's own), does not verify the
# server's certificate. That fetch is still verified: apt checks
# the snapshot's InRelease against the ubuntu-keyring the base ships, and each
# package against the SHA-256 in that signed index, as it does over the plain
# http archive.ubuntu.com the base is configured with. Every fetch after it
# verifies the certificate too.
#
# Every fetch survives a short upstream outage, under the bounded-retry rule of
# keploy/ebpf's .woodpecker/fetch.sh: a bounded number of attempts, spaced so
# that a blip (a run of 5xx, a mirror restart) does not use them all up in
# seconds. apt 2.4 retries a file after a transient failure (HTTP 408, 429, 500,
# 502, 503, 504 or 599, or a timeout), waiting min(2^n, Maximum) s before
# retry n+1. Its default, 3 retries, spans 7 s; at v1.2.43 snapshot.ubuntu.com
# answered 503 for longer than that, to every file. 7 retries capped at 40 s
# wait 1+2+4+8+16+32+40 = 103 s, the span of fetch.sh's 10+20+30+40 s. And
# apt-get update fails when it cannot fetch an index (Error-Mode any): by
# default it only warns about a transient failure and exits 0, and the build
# then failed on "Version ... was not found" rather than on the 503.
# Build-time only: the file goes with the package lists.
RUN set -eux; \
    printf '%s\n' 'Acquire::Retries "7";' 'Acquire::Retries::Delay::Maximum "40";' \
        'APT::Update::Error-Mode "any";' > /etc/apt/apt.conf.d/80-build-fetch; \
    printf 'deb https://snapshot.ubuntu.com/ubuntu/%s %s main universe\n' \
        "$SNAPSHOT" jammy "$SNAPSHOT" jammy-updates "$SNAPSHOT" jammy-security \
        > /etc/apt/sources.list; \
    apt-get -o Acquire::https::Verify-Peer=false update; \
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::https::Verify-Peer=false \
        install -y --no-install-recommends ca-certificates=20260601~22.04.1 \
        openssl=3.0.2-0ubuntu1.30 libssl3=3.0.2-0ubuntu1.30; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        clang-14=1:14.0.0-1ubuntu1.1 \
        llvm-14=1:14.0.0-1ubuntu1.1 \
        libbpf-dev=1:0.5.0-1ubuntu22.04.1 \
        linux-libc-dev=5.15.0-198.208 \
        linux-libc-dev-arm64-cross=5.15.0-22.22cross3 \
        libc6-dev=2.35-0ubuntu3.15 \
        libc6-dev-arm64-cross=2.35-0ubuntu1cross3 \
        git=1:2.34.1-1ubuntu1.17; \
    rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/80-build-fetch; \
    ln -sf /usr/bin/llvm-strip-14 /usr/bin/llvm-strip; \
    ln -sf /usr/bin/clang-14 /usr/bin/clang

COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=local

# A broken toolchain fails here, not in the lane: build a BPF object for each
# target with compile.sh's include paths, from the kernel and libbpf headers,
# and strip it.
RUN set -eux; \
    go version | grep -qF 'go1.27.1 linux/amd64'; \
    printf '#include <linux/bpf.h>\n#include <linux/types.h>\n#include <asm/types.h>\n#include <bpf/bpf_helpers.h>\nSEC("tracepoint/x") int probe(void *ctx) { return 0; }\nchar LICENSE[] SEC("license") = "GPL";\n' > /tmp/probe.c; \
    clang -target bpf -O2 -g -D__x86_64__ -I/usr/include/x86_64-linux-gnu -c /tmp/probe.c -o /tmp/probe-x86.o; \
    clang -target bpf -O2 -g -D__aarch64__ -I/usr/aarch64-linux-gnu/include -I/usr/include/aarch64-linux-gnu -c /tmp/probe.c -o /tmp/probe-arm64.o; \
    llvm-strip -g /tmp/probe-x86.o /tmp/probe-arm64.o; \
    rm -f /tmp/probe.c /tmp/probe-x86.o /tmp/probe-arm64.o
