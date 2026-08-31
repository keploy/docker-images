# keploy-ci-golint: Go + golangci-lint pre-installed
# Used by: golangci-lint.yml
FROM public.ecr.aws/docker/library/golang:1.27-bookworm

ARG GOLANGCI_LINT_VERSION=v2.13.2

RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*; \
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh \
      | sh -s -- -b /usr/local/bin "${GOLANGCI_LINT_VERSION}"; \
    golangci-lint --version
