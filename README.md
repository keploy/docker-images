# Keploy Docker Images

This repository contains Docker images used by Keploy for CI/CD pipelines.

## Images

### keploy-ci

A Docker-in-Docker image with Go and common CI dependencies for running Keploy tests in CI pipelines.

**Features:**
- Based on `docker:26.1-dind` (includes dockerd, docker CLI, buildx, containerd, runc)
- Go 1.25.0 with CGO enabled
- Common CI utilities (bash, curl, git, jq, etc.); no MinIO client (see below)
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

## The CI object store: s3.sh, not `mc`

None of these images ships MinIO's `mc` any more. The CI store behind
`MINIO_ENDPOINT` is SeaweedFS (it replaced MinIO on 2026-09-25; the Woodpecker
secrets keep their `MINIO_*` names), and MinIO withdrew its distribution
(dl.min.io answers 410 Gone, the Docker Hub images are gone), so a baked `mc` was
a binary nobody could rebuild from upstream.

Lanes reach the store through their own repo's `.ci/scripts/s3.sh`
(`scripts/ci/s3.sh` in k8s-proxy): a POSIX-sh S3 client over the `curl` every
image here already has (curl >= 7.75; `go-build` ships 7.88.1, the rest 8.x).
It is versioned and tested with the lanes that call it, so it is not on `PATH`
in these images.

The one image-owned user of the store is `minio-cache` (node, playwright,
lighthouse; the name is historical). It speaks through the same `s3.sh`,
installed beside it at `/usr/local/lib/keploy-ci/s3.sh` and byte-identical to the
repos' copies (`docker-build.yml` checks every copy against the shared hash and
runs both against a SeaweedFS 4.47 container in the freshly built node image):

- `restore` downloads the object and verifies it (size, and MD5 where the ETag is
  one) **before** `tar` sees a byte; a miss or an unreachable store is a cold
  start (exit 0), the latter reported on stderr.
- `save` uploads with one PUT (Content-MD5, read back), so an object is replaced
  whole or not at all; a failed upload exits non-zero. Caches are limited to
  5 GiB, S3's single-PUT limit.
- It never creates a bucket (a new bucket on the store gets no retention) and
  never writes a lifecycle rule (they are locked; retention is server-side).

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
