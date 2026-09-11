# keploy-ci-kube: keploy-ci + the Kubernetes CLIs the e2e lanes need
# (kind, kubectl, helm, mikefarah/yq).
#
# WHY THIS IMAGE EXISTS
# The kube control-plane e2e lanes (k8s-proxy's e2e-*, footprint-*, and the
# enterprise DaemonSet lanes) each downloaded kind+kubectl+helm+yq from the
# public internet on every run (k8s-proxy: scripts/ci/install-tools.sh; ~73 MiB
# per lane, a WAN dependency that flakes lanes). This bakes them once, on top of
# the shared keploy-ci base (which already carries Go, the docker CLI, mc and the
# common CI utils), so those lanes drop install-tools.sh and their `apk add`
# churn entirely.
#
# This is intentionally LEAN — it does NOT descend from keploy-ci-node, so it
# carries no Node.js/Chromium weight. keploy-ci-playwright keeps the SAME tool
# versions (see the ARG block there, kept in step with this one) but stays on its
# own node lineage; it cannot simply build FROM this image because it needs Node.
#
# HOW TO USE IT (important): run it as a docker CLIENT against a SIBLING
# docker:dind service (set DOCKER_HOST to the sibling). Do NOT start this image's
# own dockerd via `start-docker` — running kind inside a nested dockerd is
# unreliable, which is the documented reason the e2e lanes use a sibling dind.
# The base tag is a BUILD ARG, not a frozen literal.
#
# Every derived image here used to hard-code `FROM ghcr.io/keploy/keploy-ci:<tag>`,
# and nothing ever moved those literals: publish.yml rebuilds all variants on each
# release, but each one kept building on whatever base tag was current the day it
# was written. keploy-ci-node sat on 1.2.23 for nine releases, so when the base
# moved to Go 1.27 (#21) node — and everything FROM node, including playwright —
# silently stayed on Go 1.26. Downstream repos then built go-1.27 modules in a
# go-1.26 image and, because these images default GOTOOLCHAIN=auto, pulled a
# ~325MB toolchain at pipeline time instead of failing.
#
# publish.yml now passes BASE_TAG=<version being published>, so a derived image
# always sits on the base from the SAME release. The default below is only for a
# bare `docker build` outside CI.
ARG BASE_TAG=1.2.36
FROM ghcr.io/keploy/keploy-ci:${BASE_TAG}
# ── STANDARD Kubernetes tool versions ─────────────────────────────────────────
# Single source of truth for every consuming lane. keploy-ci-playwright pins the
# same values in its own ARG block; keep the two in step if either moves.
#   kubectl/kind track kindest/node:v1.31.0 (the e2e node image).
ARG KIND_VERSION=v0.24.0
ARG KUBECTL_VERSION=v1.31.0
ARG HELM_VERSION=v3.17.3
ARG YQ_VERSION=v4.44.3

# Provided automatically by BuildKit/buildx; fall back to dpkg when unset.
ARG TARGETARCH

RUN set -eux; \
    ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$ARCH" in \
        amd64|arm64) ;; \
        *) echo "Unsupported architecture: $ARCH"; exit 1 ;; \
    esac; \
    # kind
    curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"; \
    chmod +x /usr/local/bin/kind; \
    # kubectl
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    chmod +x /usr/local/bin/kubectl; \
    # helm
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz -C /tmp --strip-components=1 "linux-${ARCH}/helm"; \
    install -m 0755 /tmp/helm /usr/local/bin/helm; \
    rm -f /tmp/helm; \
    # yq — MUST be mikefarah/yq (the Go binary), NOT the python `yq` wrapper,
    # whose `-i` semantics differ and would corrupt the kubeconfig rewrite in
    # k8s-proxy's setup-cluster.sh.
    curl -fsSLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"; \
    chmod +x /usr/local/bin/yq; \
    # verify
    kind version; \
    kubectl version --client; \
    helm version --short; \
    yq --version | grep -qF 'mikefarah/yq'

# PyYAML for python3. k8s-proxy's ds-node-pinning e2e (tests/e2e/ds-node-pinning/
# run.sh) parses pod/report YAML and `helm template` output with python3's `yaml`
# module — the only kube e2e lane that does. It was `py3-yaml` on the old Alpine
# docker:cli image; the base keploy-ci carries python3 but not this module, so a
# lane on this image otherwise had to `apt-get install python3-yaml` at RUN time
# (a per-run WAN install this image exists to eliminate). Bake it here.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3-yaml; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    # verify the module imports (fail the build, not the lane)
    python3 -c 'import yaml; print("PyYAML", yaml.__version__)'
