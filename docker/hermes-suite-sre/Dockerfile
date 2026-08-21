# hermes-suite-sre - Hermes Suite + pinned SRE/GitOps tooling.
#
# Base: ascensionoid/hermes-suite (gateway+dashboard+webui via supervisord,
# runs as uid/gid 10000 "hermes"). This layer adds the CLI tools Hermes needs
# to actually operate the homelab (kubectl/flux/helm/git/sops/age/yq/
# kustomize/jq/openssl/dig/nc) without becoming a general debugging toolbox.
#
# Build: docker build -t hermes-suite-sre:<tag> -f docker/hermes-suite-sre/Dockerfile .
# Published as: ghcr.io/shubhamwagh/hermes-suite-sre:<AGENT_VERSION>-<TOOLS_REVISION>
#
# All binaries fetched over HTTPS from official upstream GitHub
# releases/dl.k8s.io at pinned versions. kubectl is checksum-verified
# against upstream's published .sha256 (the one tool here handling live
# cluster-admin-adjacent traffic); the others are pinned-version release
# tarballs/binaries served over TLS from their own project's release
# infrastructure - no `curl | bash`, no third-party installer scripts.
ARG AGENT_VERSION=2026.7.20-0.52.106
FROM ascensionoid/hermes-suite:${AGENT_VERSION}

USER root

# Pinned to match this homelab's actual k3s server (v1.35.4+k3s1) and the
# same tool versions already used locally via mise, for consistency.
ARG KUBECTL_VERSION=1.35.4
ARG HELM_VERSION=4.2.2
ARG FLUX_VERSION=2.9.0
ARG YQ_VERSION=4.53.3
ARG KUSTOMIZE_VERSION=5.5.0
ARG SOPS_VERSION=3.13.2
ARG AGE_VERSION=1.3.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      jq \
      dnsutils \
      netcat-openbsd \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# kubectl - checksum-verified against upstream's published .sha256
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"; \
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    rm -f /tmp/kubectl.sha256

# Flux CLI - checksum-verified against upstream's published checksums.txt
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    cd /tmp; \
    curl -fsSLO "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_checksums.txt"; \
    grep " flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz$" flux_${FLUX_VERSION}_checksums.txt | sha256sum -c -; \
    tar -xzf flux_${FLUX_VERSION}_linux_${ARCH}.tar.gz -C /usr/local/bin flux; \
    chmod +x /usr/local/bin/flux; \
    rm -f /tmp/flux_*

# sops - checksum-verified against upstream's published .sha256
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSLo /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH}"; \
    curl -fsSLo /tmp/sops.checksums.txt "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.checksums.txt"; \
    grep "sops-v${SOPS_VERSION}.linux.${ARCH}$" /tmp/sops.checksums.txt | sha256sum -c -; \
    chmod +x /usr/local/bin/sops; \
    rm -f /tmp/sops.checksums.txt

# helm - pinned-version release tarball over HTTPS from get.helm.sh
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tgz; \
    tar -xzf /tmp/helm.tgz -C /tmp; \
    mv "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm; \
    chmod +x /usr/local/bin/helm; \
    rm -rf /tmp/helm.tgz "/tmp/linux-${ARCH}"

# yq - pinned-version release binary over HTTPS from GitHub releases
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}"; \
    chmod +x /usr/local/bin/yq

# kustomize - pinned-version release tarball over HTTPS from GitHub releases
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" -o /tmp/kustomize.tgz; \
    tar -xzf /tmp/kustomize.tgz -C /usr/local/bin kustomize; \
    chmod +x /usr/local/bin/kustomize; \
    rm -f /tmp/kustomize.tgz

# age / age-keygen - pinned-version release tarball over HTTPS from GitHub releases
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/age.tgz; \
    tar -xzf /tmp/age.tgz -C /tmp; \
    mv /tmp/age/age /tmp/age/age-keygen /usr/local/bin/; \
    rm -rf /tmp/age.tgz /tmp/age

# git, openssl already present in the base image (per upstream Dockerfile);
# grep/sed/awk/tar/gzip are standard on Debian, already present.

USER hermes
