# syntax=docker/dockerfile:1

FROM debian:13-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS builder-tools

ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=24
ARG OPENCODE_VERSION=2.3.0
# sha256 of the npm platform tarball for OPENCODE_VERSION. Set empty to fall
# back to the sha512 integrity reported by the npm registry (weaker: the
# registry vouches for its own bytes).
ARG OPENCODE_SHA256=408f854b5fac7857a3b4df4e783d3a8b70f5cc8c7c3187aac09c5be0576c14ae
ARG BDUI_VERSION=0.12.6

# BuildKit supplies proxy build arguments from the builder environment. They are
# exported only for the commands that need them and are not stored as ENV.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV DEBIAN_FRONTEND=noninteractive

RUN export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"; \
    apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# The custom bundle is optional. Mounting the build context keeps it out of an
# image layer until its individual certificates are installed into the trust store.
RUN --mount=type=bind,source=.,target=/build-context,ro \
    set -eu; \
    if [ -s /build-context/custom-ca.crt ]; then \
      mkdir -p /usr/local/share/ca-certificates; \
      awk '\
        /-----BEGIN CERTIFICATE-----/ {\
          n++;\
          output=sprintf("/usr/local/share/ca-certificates/opencode-custom-ca-%03d.crt", n);\
          in_cert=1;\
        }\
        in_cert { print > output }\
        /-----END CERTIFICATE-----/ { close(output); in_cert=0 }\
      ' /build-context/custom-ca.crt; \
      found=0; \
      for certificate in /usr/local/share/ca-certificates/opencode-custom-ca-*.crt; do \
        [ -f "$certificate" ] || continue; \
        found=1; \
        if ! openssl x509 -in "$certificate" -noout >/dev/null 2>&1; then \
          echo "invalid PEM X.509 certificate in custom-ca.crt: $certificate" >&2; \
          exit 1; \
        fi; \
      done; \
      if [ "$found" -eq 0 ]; then \
        echo "custom-ca.crt does not contain a PEM X.509 certificate" >&2; \
        exit 1; \
      fi; \
      update-ca-certificates; \
    fi

# npm does not automatically use Debian's system CA bundle for registry TLS.
ENV NPM_CONFIG_CAFILE=/etc/ssl/certs/ca-certificates.crt

RUN export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"; \
    apt-get update && apt-get install --no-install-recommends -y \
    curl \
    gnupg \
    git \
    python3 \
    python3-venv \
    ripgrep \
    jq \
    && rm -rf /var/lib/apt/lists/*

RUN export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"; \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource-repo.gpg.key && \
    test "$(gpg --show-keys --with-colons --fingerprint /tmp/nodesource-repo.gpg.key | awk -F: '$1 == "fpr" { print $10; exit }')" = "6F71F525282841EEDAF851B42F59B5F99B1BE0B4" && \
    gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg /tmp/nodesource-repo.gpg.key && \
    rm -f /tmp/nodesource-repo.gpg.key && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install --no-install-recommends -y nodejs && \
    npm install --global --no-audit --no-fund npm@12.0.2 && \
    rm -rf /var/lib/apt/lists/*

# Install OpenCode from the npm platform tarball instead of the opencode.ai
# installer script: the installer gets republished without version changes,
# which breaks its pinned hash. The tarball is content-addressed, so
# OPENCODE_VERSION + OPENCODE_SHA256 pin the exact binary bytes.
# Target is glibc linux-x64 with AVX2 (the installer default on such CPUs).
RUN export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"; \
    echo "Installing OpenCode version: ${OPENCODE_VERSION}" && \
    curl -fsSL "https://registry.npmjs.org/@opencode%2fcli-linux-x64/-/cli-linux-x64-${OPENCODE_VERSION}.tgz" -o /tmp/opencode.tgz && \
    if [ -n "${OPENCODE_SHA256}" ]; then \
      echo "${OPENCODE_SHA256}  /tmp/opencode.tgz" | sha256sum -c -; \
    else \
      echo "WARNING: OPENCODE_SHA256 empty; checking registry-reported integrity only" >&2; \
      integrity=$(curl -fsSL "https://registry.npmjs.org/@opencode%2fcli-linux-x64/${OPENCODE_VERSION}" | jq -r '.dist.integrity'); \
      [ "sha512-$(openssl dgst -sha512 -binary /tmp/opencode.tgz | openssl base64 -A)" = "$integrity" ]; \
    fi && \
    tar xzf /tmp/opencode.tgz -C /tmp && \
    install -m 0755 /tmp/package/bin/opencode /usr/local/bin/opencode && \
    rm -rf /tmp/opencode.tgz /tmp/package && \
    opencode --version

RUN export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"; \
    npm install --global --no-audit --no-fund "beads-ui@${BDUI_VERSION}" && \
    bdui --version

RUN node --version && \
    npm --version && \
    python3 --version && \
    python3 -m venv /tmp/test-venv && \
    rm -rf /tmp/test-venv && \
    opencode --version

COPY scripts/collect-runtime-deps.sh /usr/local/bin/collect-runtime-deps.sh
RUN chmod 0755 /usr/local/bin/collect-runtime-deps.sh

# Agent tooling: beads (bd), herdr, lazygit, ttt, and uv release binaries, pinned
# by version and sha256. Assets and checksums come from the upstream releases:
#   beads:    https://github.com/gastownhall/beads/releases (beads_<ver>_linux_<arch>.tar.gz)
#   herdr:    https://herdr.dev/latest.json (same manifest `herdr update` uses)
#   lazygit:  https://github.com/jesseduffield/lazygit/releases (lazygit_<ver>_linux_<arch>.tar.gz)
#   ttt:      https://github.com/eugenioenko/ttt/releases (ttt-linux-<arch>)
#   uv:       https://github.com/astral-sh/uv/releases (uv_<arch>-unknown-linux-gnu.tar.gz + .sha256)
FROM debian:13-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS agent-tools

ARG BD_VERSION=1.3.4
ARG BD_SHA256_AMD64=175c26904bde3ff9168d2282ff6b56f17b17f60c22fa5acb3dacc9fb3465303a
ARG BD_SHA256_ARM64=f4ee6eb3ec79bb2d7eb9d717c73efbcb6fa763cc70f726b4d055b72afdd68ad5
ARG HERDR_VERSION=0.9.5
ARG HERDR_SHA256_AMD64=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
ARG HERDR_SHA256_ARM64=17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c
ARG LAZYGIT_VERSION=0.66.3
ARG LAZYGIT_SHA256_AMD64=0a23f429a95f0d09db298b3c291536d818de066aa5a85c255806f0490ff6656b
ARG LAZYGIT_SHA256_ARM64=ac0b48237f3d0283813e7154ec063237e519532feb0470c0881a1793ee78fd42
ARG TTT_VERSION=1.12.1
ARG TTT_SHA256_AMD64=e6b5bb64b897810349fb46f8319559f65c6e5f1a40e26a93bd6860b6f7f7b6de
ARG TTT_SHA256_ARM64=f88c3f38b726efb1ce35dede745e6a0f3d7083c15fd6f75f17dc8fb68c7c857b
ARG UV_VERSION=0.13.9
ARG UV_SHA256_AMD64=a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5
ARG UV_SHA256_ARM64=0797542018e541a9288855df555c8077eed06f7a47d206362030480e8ecc9f3d
ARG TARGETARCH
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV DEBIAN_FRONTEND=noninteractive

RUN export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"; \
    apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates \
    curl \
    tar \
    && rm -rf /var/lib/apt/lists/*

RUN export http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"; \
    set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) bd_arch=amd64; herdr_arch=x86_64; lazygit_arch=x86_64; ttt_arch=amd64; uv_triple=x86_64-unknown-linux-gnu; bd_sha="$BD_SHA256_AMD64"; herdr_sha="$HERDR_SHA256_AMD64"; lazygit_sha="$LAZYGIT_SHA256_AMD64"; ttt_sha="$TTT_SHA256_AMD64"; uv_sha="$UV_SHA256_AMD64" ;; \
      arm64) bd_arch=arm64; herdr_arch=aarch64; lazygit_arch=arm64; ttt_arch=arm64; uv_triple=aarch64-unknown-linux-gnu; bd_sha="$BD_SHA256_ARM64"; herdr_sha="$HERDR_SHA256_ARM64"; lazygit_sha="$LAZYGIT_SHA256_ARM64"; ttt_sha="$TTT_SHA256_ARM64"; uv_sha="$UV_SHA256_ARM64" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    workdir="$(mktemp -d)"; cd "$workdir"; \
    curl -fsSL -o bd.tar.gz "https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}/beads_${BD_VERSION}_linux_${bd_arch}.tar.gz"; \
    echo "${bd_sha}  bd.tar.gz" | sha256sum -c -; \
    tar -xzf bd.tar.gz bd; \
    mkdir -p /out/bin; \
    install -m 0755 bd /out/bin/bd; \
    curl -fsSL -o herdr "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${herdr_arch}"; \
    echo "${herdr_sha}  herdr" | sha256sum -c -; \
    install -m 0755 herdr /out/bin/herdr; \
    curl -fsSL -o lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${lazygit_arch}.tar.gz"; \
    echo "${lazygit_sha}  lazygit.tar.gz" | sha256sum -c -; \
    tar -xzf lazygit.tar.gz lazygit; \
    install -m 0755 lazygit /out/bin/lazygit; \
    curl -fsSL -o ttt "https://github.com/eugenioenko/ttt/releases/download/v${TTT_VERSION}/ttt-linux-${ttt_arch}"; \
    echo "${ttt_sha}  ttt" | sha256sum -c -; \
    install -m 0755 ttt /out/bin/ttt; \
    curl -fsSL -o "uv-${uv_triple}.tar.gz" "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_triple}.tar.gz"; \
    echo "${uv_sha}  uv-${uv_triple}.tar.gz" | sha256sum -c -; \
    tar -xzf "uv-${uv_triple}.tar.gz"; \
    install -m 0755 "uv-${uv_triple}/uv" /out/bin/uv; \
    install -m 0755 "uv-${uv_triple}/uvx" /out/bin/uvx; \
    /out/bin/bd version; \
    /out/bin/herdr --version; \
    /out/bin/lazygit --version; \
    /out/bin/ttt --version; \
    /out/bin/uv --version; \
    cd /; rm -rf "$workdir"

FROM builder-tools AS collector

# Copy the pinned agent tools into the collector so ldd-based dependency
# collection picks up any shared libraries they need.
COPY --from=agent-tools /out/bin/bd /usr/local/bin/bd
COPY --from=agent-tools /out/bin/herdr /usr/local/bin/herdr
COPY --from=agent-tools /out/bin/lazygit /usr/local/bin/lazygit
COPY --from=agent-tools /out/bin/ttt /usr/local/bin/ttt
COPY --from=agent-tools /out/bin/uv /usr/local/bin/uv
COPY --from=agent-tools /out/bin/uvx /usr/local/bin/uvx
RUN ln -s bd /usr/local/bin/beads

ARG USER_UID=1000
ARG USER_GID=1000

RUN mkdir -p /opt/runtime-rootfs && \
    /usr/local/bin/collect-runtime-deps.sh /opt/runtime-rootfs \
      opencode node npm python3 git \
      bd beads herdr lazygit ttt bdui uv uvx \
      /usr/lib/git-core/git-remote-http /usr/lib/git-core/git-remote-https \
      mkdir find grep rg jq cat head tail sed awk \
      ls cp mv rm chmod wc sort cut env date dirname basename sh

RUN cd /opt/runtime-rootfs && \
    for dir in bin sbin; do \
      if [ -d "${dir}" ] && [ ! -L "${dir}" ]; then \
        mkdir -p "usr/${dir}"; \
        if [ -n "$(ls -A "${dir}" 2>/dev/null)" ]; then \
          cp -a "${dir}"/. "usr/${dir}"/; \
        fi; \
        rm -rf "${dir}"; \
      fi; \
    done && \
    rm -rf bin sbin && \
    for dir in lib lib64; do \
      if [ -d "${dir}" ] && [ ! -L "${dir}" ]; then \
        mkdir -p "usr/${dir}"; \
        cp -a "${dir}"/. "usr/${dir}"/; \
      fi; \
    done && \
    rm -rf lib lib64 && \
    [ -L usr/bin/sh ] && [ -x ".$(readlink usr/bin/sh)" ]

RUN mkdir -p /opt/runtime-rootfs/app/.local/share /opt/runtime-rootfs/app/.local/state /opt/runtime-rootfs/app/.config/opencode /opt/runtime-rootfs/app/.cache && \
    mkdir -p /opt/runtime-rootfs/opt && \
    ln -s /opt/my-skills /opt/runtime-rootfs/opt/skills && \
    chown -R ${USER_UID}:${USER_GID} /opt/runtime-rootfs/app && \
    # Login shell must be the shipped POSIX shell, not python3: herdr resolves
    # pane shells from /etc/passwd and exports $SHELL, and OpenCode's shell tool
    # honors $SHELL — a python3 login shell makes it exec every command as
    # Python source (SyntaxError/NameError).
    printf 'opencode:x:%s:%s:OpenCode User:/app:/usr/bin/sh\n' "${USER_UID}" "${USER_GID}" >> /opt/runtime-rootfs/etc/passwd && \
    printf 'opencode:x:%s:\n' "${USER_GID}" >> /opt/runtime-rootfs/etc/group

FROM gcr.io/distroless/base-debian13@sha256:9ef50bca108839d5986e4d84b7f7b2d79024c9293b7c35b162c6c55485bd5868 AS final

ARG USER_UID=1000
ARG USER_GID=1000

WORKDIR /app

ENV HOME=/app
ENV XDG_CONFIG_HOME=/app/.config
ENV OPENCODE_CONFIG_DIR=/app/.config/opencode
ENV XDG_DATA_HOME=/app/.local/share
ENV XDG_STATE_HOME=/app/.local/state
ENV PATH=/usr/local/bin:/usr/bin
ENV NPM_CONFIG_CAFILE=/etc/ssl/certs/ca-certificates.crt

COPY --from=collector /opt/runtime-rootfs/ /
COPY --chmod=0755 bootstrap.py /usr/local/bin/bootstrap.py

# Skills library vendored from tslator/my-skills (see `bin/oc-dev skills`); root-owned
# so the agent cannot edit its own skill sources. The /opt/skills symlink ships
# via the collector rootfs (distroless has no ln) as a stable indirection so
# config paths survive repo-layout changes.
COPY vendor/my-skills /opt/my-skills

USER ${USER_UID}:${USER_GID}

ENTRYPOINT ["/usr/bin/python3", "/usr/local/bin/bootstrap.py"]
