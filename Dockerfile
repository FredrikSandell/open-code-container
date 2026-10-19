# syntax=docker/dockerfile:1
ARG BASE_IMAGE=node:22-trixie-slim
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=1.19.3
ARG GH_VERSION=2.101.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq less openssh-client openssl procps ripgrep tini util-linux \
 && rm -rf /var/lib/apt/lists/*

RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
    | tar -xz -C /tmp \
 && install -m 755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/bin/gh \
 && rm -rf /tmp/gh_*

RUN npm install -g "opencode-ai@${OPENCODE_VERSION}" \
 && npm cache clean --force \
 && opencode --version

COPY rootfs/ /
RUN chmod 755 /opt/occ/entrypoint.sh /opt/occ/bin/* /opt/occ/git-hooks/dispatch \
 && cd /opt/occ/git-hooks \
 && for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit \
      prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge \
      pre-push post-rewrite push-to-checkout; do ln -s dispatch "$h"; done

RUN useradd --create-home --uid 10001 --user-group --shell /bin/bash opencode
USER 10001:10001
WORKDIR /home/opencode

ENV HOME=/home/opencode \
    PATH=/opt/occ/bin:$PATH \
    OPENCODE_CONFIG=/etc/opencode/opencode.json \
    OCC_PORT=4096

EXPOSE 4096
VOLUME ["/home/opencode"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s CMD ["/opt/occ/bin/occ-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/occ/entrypoint.sh"]
