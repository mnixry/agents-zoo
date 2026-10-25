# syntax=docker/dockerfile:1
# Everything tracks latest. Remote ADDs are revalidated on every build, so a new
# release re-runs the steps after its ADD (versioned assets are triggered by the
# release feed, npm "latest" document or upstream package.json). --no-cache also
# refreshes the Debian packages.

FROM debian:trixie AS fetch
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl

FROM fetch AS nu
ADD https://github.com/nushell/nushell/releases.atom /releases.atom
RUN tag=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/nushell/nushell/releases/latest) \
  && name="nu-${tag##*/}-$(uname -m)-unknown-linux-musl" \
  && curl -fsSL "https://github.com/nushell/nushell/releases/download/${tag##*/}/$name.tar.gz" \
  | tar -xz -C /usr/local/bin --no-same-owner --strip-components=1 "$name/nu"

FROM fetch AS uv
ADD https://astral.sh/uv/install.sh /install.sh
RUN UV_INSTALL_DIR=/out UV_NO_MODIFY_PATH=1 sh /install.sh

FROM fetch AS kasmvnc
ARG TARGETARCH
ADD https://github.com/kasmtech/KasmVNC/releases.atom /releases.atom
RUN tag=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/kasmtech/KasmVNC/releases/latest) \
  && curl -fsSL "https://github.com/kasmtech/KasmVNC/releases/expanded_assets/${tag##*/}" \
  | grep -om1 "/kasmtech/KasmVNC/releases/download/[^\"]*_debian_trixie_[^\"]*_${TARGETARCH}.deb" \
  | xargs -I{} curl -fsSLo /kasmvncserver.deb "https://github.com{}"

FROM fetch AS process-compose
ARG TARGETARCH
ADD https://github.com/F1bonacc1/process-compose/releases/latest/download/process-compose_linux_${TARGETARCH}.tar.gz /process-compose.tar.gz
RUN tar -xzf /process-compose.tar.gz -C /usr/local/bin process-compose

FROM scratch AS npm-latest
ADD https://registry.npmjs.org/@anthropic-ai/claude-code/latest /claude-code.json
ADD https://registry.npmjs.org/@openai/codex/latest /codex.json
ADD https://registry.npmjs.org/@opencode/cli/latest /opencode-cli.json
ADD https://registry.npmjs.org/@moonshot-ai/kimi-code/latest /kimi-code.json
ADD https://registry.npmjs.org/mcp-remote/latest /mcp-remote.json
ADD https://registry.npmjs.org/@playwright/mcp/latest /playwright-mcp.json
ADD https://registry.npmjs.org/pnpm/latest /pnpm.json

FROM fetch AS raft
ADD https://raw.githubusercontent.com/botiverse/raft-source/main/packages/computer/package.json /dev/null
ADD https://cdn.raft.build/computer/install.sh /install.sh
ENV HOME=/tmp RAFT_COMPUTER_INSTALL_DIR=/out/usr/local/bin RAFT_COMPUTER_NO_MODIFY_PATH=1
RUN sh /install.sh install --yes && chmod 0644 /out/usr/local/bin/photon_rs_bg.wasm

FROM debian:trixie
ARG DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,id=apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=apt-lists,target=/var/lib/apt/lists,sharing=locked \
  rm -f /etc/apt/apt.conf.d/docker-clean \
  && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
  && echo 'locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8' | debconf-set-selections \
  && echo 'locales locales/default_environment_locale select en_US.UTF-8' | debconf-set-selections \
  && apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates curl git openssh-client sudo less procps unzip xz-utils \
  tzdata locales tini xdg-utils \
  build-essential pkg-config cmake ninja-build libssl-dev \
  && useradd --create-home --shell /bin/bash --user-group --groups sudo agent \
  && install -d -o agent -g agent /var/log/agents-zoo \
  && install -d /etc/xdg/process-compose
ENV LANG=en_US.UTF-8 TZ=Etc/UTC

RUN --mount=type=cache,id=apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=apt-lists,target=/var/lib/apt/lists,sharing=locked \
  --mount=type=bind,from=kasmvnc,source=/kasmvncserver.deb,target=/mnt/kasmvncserver.deb \
  apt-get update && apt-get install -y --no-install-recommends /mnt/kasmvncserver.deb \
  dbus dbus-x11 xauth x11-utils x11-xserver-utils xdotool \
  xfwm4 tint2 xsettingsd xwallpaper xfce4-terminal xfce4-taskmanager \
  greybird-gtk-theme elementary-xfce-icon-theme \
  fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
  && usermod -aG ssl-cert agent

RUN --mount=type=cache,id=apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=apt-lists,target=/var/lib/apt/lists,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends chromium

ADD --chmod=644 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key /usr/share/keyrings/nodesource.asc
COPY build/nodesource.sources /etc/apt/sources.list.d/
RUN --mount=type=cache,id=apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=apt-lists,target=/var/lib/apt/lists,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends nodejs

# Install scripts that matter: claude-code and @opencode/cli link their native
# binary, pnpm swaps in its native binary, node-pty builds Kimi's terminal addon.
# npm 11 only warns about unlisted ones (Kimi's legacy-shim migration) for now.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false PNPM_HOME=/opt/pnpm
RUN --mount=type=bind,from=npm-latest,target=/mnt/npm-latest \
  --mount=type=cache,id=npm,target=/root/.npm \
  --mount=type=cache,id=node-gyp,target=/root/.cache \
  --mount=type=tmpfs,target=/tmp \
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --global --no-audit \
  --allow-scripts=@anthropic-ai/claude-code,@opencode/cli,pnpm,node-pty \
  @anthropic-ai/claude-code @openai/codex @opencode/cli @moonshot-ai/kimi-code \
  mcp-remote @playwright/mcp pnpm \
  && rm -rf /root/.config /root/.local \
  && mkdir -p "$PNPM_HOME/bin" && chown -R agent:agent "$PNPM_HOME"

COPY --link --from=uv /out/ /usr/local/bin/
COPY --link --from=nu /usr/local/bin/nu /usr/local/bin/
COPY --link --from=process-compose /usr/local/bin/process-compose /usr/local/bin/
COPY --link --from=raft /out/ /
COPY --link rootfs/ /

ENV PATH=/home/agent/.local/bin:/opt/pnpm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  DISPLAY=:1 \
  XAUTHORITY=/run/agent/Xauthority \
  XDG_RUNTIME_DIR=/run/agent \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/agent/bus \
  PC_SOCKET_PATH=/run/agent/process-compose.sock \
  PC_LOG_FILE=/var/log/agents-zoo/process-compose.log \
  BROWSER=/usr/local/bin/open-browser \
  DISABLE_AUTOUPDATER=1 \
  KIMI_CODE_NO_AUTO_UPDATE=1 \
  OPENCODE_DISABLE_AUTOUPDATE=1 \
  RAFT_COMPUTER_EXTERNAL_SUPERVISOR=1

EXPOSE 6901
VOLUME /home/agent
ENTRYPOINT ["tini", "--", "/usr/local/bin/agents-zoo-init"]
