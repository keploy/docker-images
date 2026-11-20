# keploy-ci-scripts: the image k8s-proxy's ci-script-tests step runs in, the
# shell unit tests of its CI scripts.
#
# The step used to `apk add` what it needs from dl-cdn.alpinelinux.org as it
# ran, so a mirror blip turned a pipeline red with no change in it (k8s-proxy
# main pipeline 10132: "IO ERROR" on `apk add git`). Here every package it
# needs is in the image, and the step downloads nothing.
#
# Its tests run under busybox's tools on purpose: a CI script must work under
# busybox ash and its applets (alpine step images), dash and bash, and under
# GNU coreutils and the awks of the Debian-based ones. So the image installs
# up front only what the step installed before its first test (of these only
# GNU tar replaces a busybox applet). The rest are .apk files under
# /opt/apk/<group>/, which the step installs from the image alone at the point
# its tests first need them, in this order (each group resolves against the
# ones before it):
#
#   apk add --no-network --no-cache /opt/apk/python3/*.apk
#   apk add --no-network --no-cache /opt/apk/zip/*.apk
#   apk add --no-network --no-cache /opt/apk/coreutils/*.apk   # GNU date, sleep, timeout, setsid...
#   apk add --no-network --no-cache /opt/apk/awk/*.apk         # gawk becomes awk
#
# alpine 3.20: the busybox the step's awk rows name as the older one
# (alpine/helm's is newer).
FROM alpine:3.20.10@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc AS base

# yq-go is mikefarah/yq, the Go binary the pipelines and keploy-ci-kube use;
# never alpine's `yq` package, the Python wrapper that parses YAML differently.
# GNU tar for zstd (busybox tar has none).
RUN apk add --no-cache yq-go git bash jq dash openssl tar zstd

FROM base AS resolve
COPY fetch-groups.sh /fetch-groups.sh
RUN sh /fetch-groups.sh /out \
      python3 python3 -- \
      zip zip -- \
      coreutils coreutils util-linux-misc -- \
      awk gawk mawk

FROM base
COPY --from=resolve /out /opt/apk
