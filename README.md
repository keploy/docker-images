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
image: ghcr.io/keploy/keploy-ci:kube-latest
```

Tag: `ghcr.io/keploy/keploy-ci:kube-<version>`.

## Publishing

Images are automatically published to GitHub Container Registry (ghcr.io) when:
- A new tag is pushed (e.g., `v1.0.0`)
- A new release is published

Tags follow semantic versioning:
- `v1.0.0` → `1.0.0`, `1.0`, `1`, `latest`
