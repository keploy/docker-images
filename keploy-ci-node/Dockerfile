# keploy-ci-node: keploy-ci + Node.js 20 + minio-cache (DinD + eBPF capable)
# Used by: node-linux.yml, node-docker-linux.yml, enterprise-ui node-ci.yml
FROM ghcr.io/keploy/keploy-ci:1.2.14

RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
    apt-get install -y --no-install-recommends nodejs zstd; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version

# Cache helper script for MinIO-backed caching (zstd compressed).
COPY minio-cache /usr/local/bin/minio-cache
RUN chmod +x /usr/local/bin/minio-cache
