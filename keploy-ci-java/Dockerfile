# keploy-ci-java: keploy-ci + Maven + JDK (DinD + eBPF capable)
# Used by: java-linux.yml
FROM ghcr.io/keploy/keploy-ci:1.2.8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        maven \
        default-jdk \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    java -version; \
    mvn -version
