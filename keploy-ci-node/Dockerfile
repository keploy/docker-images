# keploy-ci-node: keploy-ci + Node.js 20 (DinD + eBPF capable)
# Used by: node-linux.yml, node-docker-linux.yml
FROM ghcr.io/keploy/keploy-ci:1.2.8

RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version
