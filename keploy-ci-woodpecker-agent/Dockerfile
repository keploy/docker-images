# keploy-ci-woodpecker-agent: the Woodpecker CI agent, built from upstream's
# source at WOODPECKER_TAG with the patches in patches/ applied.
# Used by: the Linux Woodpecker agents (docker), in place of
# woodpeckerci/woodpecker-agent at the same version.
#
# Why: the v3.20.1 agent counts WOODPECKER_RETRY_TIMEOUT (2 minutes by default)
# from the moment an RPC began. Wait() stays open for the whole workflow, so
# the first dropped connection after two minutes gets no retry and the agent
# cancels every workflow it is running, with every step marked killed.
# 0001 is woodpecker-ci/woodpecker#7111 (for issue #7110), still open
# upstream, applied to v3.20.1; 0002 adds the tests for the failure as it
# happened here; 0003 starts the window over once the agent has reconnected,
# so a drop soon after a reconnection is retried too. When an upstream release
# carries these fixes, go back to upstream's image and delete this one.
#
# Follows upstream's docker/Dockerfile.agent.multiarch: the agent is built on
# the build platform for the target, and the final image is scratch.
FROM --platform=$BUILDPLATFORM golang:1.27.3-bookworm@sha256:972b4110ba0f47539a975c31e52c64765e1ff19f2d74469ae4a595c6676e80a5 AS build

ARG WOODPECKER_TAG=v3.20.1
ARG WOODPECKER_COMMIT=3f1bb0bd0db28e410ad797034d75780116122c91
# Bump with every change to patches/: the agent reports it as its version.
ARG KEPLOY_BUILD=keploy.1

RUN groupadd -g 1000 woodpecker && \
  useradd -u 1000 -g 1000 woodpecker && \
  mkdir -p /etc/woodpecker

# Upstream's image carries the backward compatible timezone names too
# (US/Eastern, Asia/Calcutta...). Bookworm's tzdata still ships them; trixie,
# which upstream builds on, moved them to tzdata-legacy.
RUN apt-get update && \
  apt-get install -y --no-install-recommends tzdata && \
  test -e /usr/share/zoneinfo/US/Eastern && \
  rm -rf /usr/share/zoneinfo/right /var/lib/apt/lists/*

# The tag must still name the commit the patches were made against.
RUN git clone --quiet --depth 1 --branch "$WOODPECKER_TAG" \
    https://github.com/woodpecker-ci/woodpecker.git /src && \
  got="$(git -C /src rev-parse HEAD)" && \
  { [ "$got" = "$WOODPECKER_COMMIT" ] || { echo "$WOODPECKER_TAG is $got, not $WOODPECKER_COMMIT" >&2; exit 1; }; }

WORKDIR /src
COPY patches/ /patches/
RUN git apply --index /patches/*.patch

# The patched package's tests, on the build platform, so a patch that no
# longer does what it says fails the build here.
RUN go test -race -count=1 -timeout 120s -tags test ./agent/rpc/

ARG TARGETOS TARGETARCH
RUN make build-agent CI_COMMIT_TAG="${WOODPECKER_TAG}-${KEPLOY_BUILD}" CI_COMMIT_SHA="$WOODPECKER_COMMIT"

FROM scratch AS stage

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group
COPY --from=build --chown=woodpecker:woodpecker /etc/woodpecker /etc

FROM scratch
ENV GODEBUG=netdns=go
# Upstream's internal setting: tells the agent it runs inside a container.
ENV WOODPECKER_IN_CONTAINER=true
EXPOSE 3000

COPY --from=stage / /
COPY --from=build /src/dist/woodpecker-agent /bin/

HEALTHCHECK CMD ["/bin/woodpecker-agent", "ping"]
ENTRYPOINT ["/bin/woodpecker-agent"]
