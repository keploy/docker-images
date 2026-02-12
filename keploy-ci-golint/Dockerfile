# keploy-ci-golint: Go + golangci-lint pre-installed
# Used by: golangci-lint.yml
FROM public.ecr.aws/docker/library/golang:1.25-bookworm

ARG GOLANGCI_LINT_VERSION=v2.9.0

RUN set -eux; \
    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh \
      | sh -s -- -b /usr/local/bin "${GOLANGCI_LINT_VERSION}"; \
    golangci-lint --version
