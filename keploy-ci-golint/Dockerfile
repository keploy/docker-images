# keploy-ci-golint: Go + golangci-lint pre-installed
# Used by: golangci-lint.yml
FROM public.ecr.aws/docker/library/golang:1.27-bookworm

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
    apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*; \
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
