# keploy-ci-python: keploy-ci + Python 3 + pip + venv (DinD + eBPF capable)
# Used by: python-linux.yml
FROM ghcr.io/keploy/keploy-ci:1.2.9

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    python3 --version; \
    pip3 --version
