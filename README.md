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

## Publishing

Images are automatically published to GitHub Container Registry (ghcr.io) when:
- A new tag is pushed (e.g., `v1.0.0`)
- A new release is published

Tags follow semantic versioning:
- `v1.0.0` → `1.0.0`, `1.0`, `1`, `latest`
