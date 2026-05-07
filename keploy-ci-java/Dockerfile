# keploy-ci-java: keploy-ci + Maven + JDK (DinD + eBPF capable)
# Used by: java-linux.yml + keploy/enterprise release pipelines, which
# stage the bundled jattach binaries from /opt/jattach/<arch>/jattach
# into a multi-arch buildx context.
FROM ghcr.io/keploy/keploy-ci:1.2.9

# Provided automatically by BuildKit/buildx; fallback to dpkg when unset
# (legacy / `docker build` without --build-arg).
ARG TARGETARCH

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        maven \
        default-jdk \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    java -version; \
    mvn -version

# Pre-stage jattach v2.2 for both linux/amd64 and linux/arm64 so release
# pipelines can `cp /opt/jattach/<arch>/jattach ./jattach-<arch>` without
# re-downloading from upstream every build. SHA256s pinned against the
# upstream-published v2.2 archives so an upstream replacement fails the
# image build instead of silently shipping a different binary.
ARG JATTACH_VERSION=v2.2
ARG JATTACH_SHA256_AMD64=acd9e17f15749306be843df392063893e97bfecc5260eef73ee98f06e5cfe02f
ARG JATTACH_SHA256_ARM64=288ae5ed87ee7fe0e608c06db5a23a096a6217c9878ede53c4e33710bdcaab51
RUN set -eux; \
    for spec in "amd64:linux-x64:${JATTACH_SHA256_AMD64}" \
                "arm64:linux-arm64:${JATTACH_SHA256_ARM64}"; do \
        out="${spec%%:*}"; rest="${spec#*:}"; \
        upstream="${rest%%:*}"; sha="${rest#*:}"; \
        mkdir -p "/opt/jattach/${out}"; \
        curl -fsSL --retry 3 --retry-delay 2 \
            -o /tmp/jattach.tgz \
            "https://github.com/jattach/jattach/releases/download/${JATTACH_VERSION}/jattach-${upstream}.tgz"; \
        echo "${sha}  /tmp/jattach.tgz" | sha256sum -c -; \
        tar -xzOf /tmp/jattach.tgz jattach > "/opt/jattach/${out}/jattach"; \
        chmod +x "/opt/jattach/${out}/jattach"; \
        rm /tmp/jattach.tgz; \
    done; \
    ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$ARCH" in amd64|arm64) ;; *) echo "unsupported ARCH='$ARCH' (supported: amd64, arm64). Build with BuildKit/buildx or pass --build-arg TARGETARCH=amd64|arm64." >&2; exit 1 ;; esac; \
    ln -s "/opt/jattach/${ARCH}/jattach" /usr/local/bin/jattach; \
    test -x /opt/jattach/amd64/jattach; \
    test -x /opt/jattach/arm64/jattach; \
    test -x /usr/local/bin/jattach; \
    /usr/local/bin/jattach 2>&1 | head -1 || true; \
    ls -la /opt/jattach/amd64/ /opt/jattach/arm64/ /usr/local/bin/jattach
