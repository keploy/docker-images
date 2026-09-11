# Keploy Docker Images

This repository contains Docker images used by Keploy for CI/CD pipelines.

## Images

### keploy-ci

A Docker-in-Docker image with Go and common CI dependencies for running Keploy tests in CI pipelines.

**Features:**
- Based on `docker:26.1-dind` (includes dockerd, docker CLI, buildx, containerd, runc)
- Go 1.25.0 with CGO enabled
- Common CI utilities (bash, curl, git, jq, etc.)
- Build dependencies for CGO builds (build-base, linux-headers)
- Helper script `start-docker` to start Docker daemon inside containers

**Usage:**
```yaml
# Example in GitHub Actions
container:
  image: ghcr.io/keploy/keploy-ci:latest
  options: --privileged
```

```bash
# Start Docker daemon inside the container
start-docker

# Docker is now ready
docker info
```

### keploy-ci-kube

`keploy-ci` plus the Kubernetes CLIs the kube control-plane e2e lanes need, baked
in so they stop downloading them from the public internet on every run.

**Adds on top of `keploy-ci`:** `kind`, `kubectl`, `helm`, and mikefarah `yq`
(pinned — the standard versions, kept in step with `keploy-ci-playwright`).

**Use it as a docker _client_ against a sibling `docker:dind` service** (point
`DOCKER_HOST` at the sibling). Do **not** run its own dockerd via `start-docker`:
running `kind` inside a nested Docker daemon is unreliable, which is why the e2e
lanes use a sibling dind.

```yaml
# Woodpecker step, talking to a sibling docker:dind service
image: ghcr.io/keploy/keploy-ci:kube-1.2.36
```

Tag: `ghcr.io/keploy/keploy-ci:kube-<version>`.

## Image tiers and the `BASE_TAG` arg

The images form a three-tier chain, and `publish.yml` builds them in that order:

| tier | images | built FROM |
|---|---|---|
| 1 | `keploy-ci`, `slim`, `timefreeze`, `golint`, `awscli`, `azurecli`, `go-build` | upstream (debian/alpine/golang) |
| 2 | `node`, `java`, `python`, `kube` | `keploy-ci:<version>` |
| 3 | `playwright`, `lighthouse` | `keploy-ci:node-<version>` |

Tiers 2 and 3 take a **`BASE_TAG` build arg** rather than hard-coding the base in
the `FROM` line, and the workflow passes the version being published. That is
load-bearing, not cosmetic:

Every derived Dockerfile used to pin a literal base tag, and nothing ever moved
those literals — so a derived image kept building on whatever base was current
the day it was written. `keploy-ci-node` sat on `keploy-ci:1.2.23` for nine
releases. When the base moved to Go 1.27, node — and therefore `playwright` and
`lighthouse`, which build FROM node — silently stayed on Go 1.26. Downstream
repos then compiled `go 1.27` modules inside a Go 1.26 image; because these
images default to `GOTOOLCHAIN=auto` that does not fail, it just downloads a
~325 MB toolchain on every cold cache.

Tier 3 is also a separate job that `needs:` tier 2. It used to share tier 2's
matrix and run in parallel with `node`, which is *why* `playwright` pinned an
already-published node tag: the node image from the same release did not exist
yet when playwright built.

The `ARG BASE_TAG=` default in each Dockerfile is only for a bare local
`docker build`; CI always overrides it.

## Publishing

Images are automatically published to GitHub Container Registry (ghcr.io) when:
- A new tag is pushed (e.g., `v1.0.0`)
- A new release is published

Tags follow semantic versioning:
- `v1.0.0` → `1.0.0`, `1.0`, `1` for every image, prefixed per variant
  (`node-1.0.0`, `playwright-1.0.0`, …)

There is **no `<prefix>-latest`**. The `latest` tag rule is
`enable={{is_default_branch}}`, which is false on the tag and release refs this
workflow runs on, so only the bare `latest` on the base image has ever been
produced — and it is stale. Pin a full `X.Y.Z` tag; every consuming repo already
does.
