# syntax=docker/dockerfile:1.7
# ---------- Stage 1: SteamCMD bootstrap ----------
FROM ubuntu:24.04 AS steamcmd

ENV DEBIAN_FRONTEND=noninteractive \
    STEAMCMD_DIR=/opt/steamcmd \
    CS2_APP_ID=730 \
    CS2_DIR=/opt/cs2

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        lib32stdc++6 \
        libcurl4 \
        libsdl2-2.0-0 \
        libzstd1 \
        libnss3 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libcups2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libxrandr2 \
        libgbm1 \
        libpango-1.0-0 \
        libcairo2 \
        libasound2t64 \
        libxshmfence1 \
        locales \
        tini \
        tzdata

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN mkdir -p ${STEAMCMD_DIR} \
    && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
       | tar -xz -C ${STEAMCMD_DIR} \
    && ${STEAMCMD_DIR}/steamcmd.sh +quit || true

# SteamCMD: cache Steam client + depots in /root/.steam for fast delta updates
# (don't mount /opt/steamcmd — that's where the binaries live, mount would mask them)
RUN --mount=type=cache,target=/root/.steam,sharing=locked \
    ${STEAMCMD_DIR}/steamcmd.sh \
        +force_install_dir ${CS2_DIR} \
        +login anonymous \
        +app_update ${CS2_APP_ID} validate \
        +quit

# ---------- Stage 2: Bake plugins (Metamod + CSS + MatchZy + WeaponPaints) ----------
FROM steamcmd AS with-plugins

USER root

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        unzip ca-certificates

COPY cs2/plugins/ /tmp/plugins/
COPY cs2/configs/ /tmp/configs/

# 1. Metamod:Source 1.11 -> csgo/addons/metamod/
RUN tar -xzf /tmp/plugins/mmsource.tar.gz -C ${CS2_DIR}/game/csgo/

# 2. CounterStrikeSharp (with runtime) -> csgo/addons/counterstrikesharp/
RUN unzip -q /tmp/plugins/css-with-runtime.zip -d ${CS2_DIR}/game/csgo/

# 3. MatchZy (zip has addons/.../MatchZy AND cfg/MatchZy at top level)
RUN unzip -q /tmp/plugins/matchzy.zip -d ${CS2_DIR}/game/csgo/

# 4. PlayerSettingsCS2 -> csgo/addons/counterstrikesharp/plugins/PlayerSettings/
RUN unzip -q /tmp/plugins/player-settings.zip -d ${CS2_DIR}/game/csgo/

# 5. AnyBaseLibCS2 -> csgo/addons/counterstrikesharp/shared/AnyBaseLib/
RUN unzip -q /tmp/plugins/any-base-lib.zip -d ${CS2_DIR}/game/csgo/

# 6. MenuManagerCS2 (zip has .../MenuManagerCore) -> csgo/addons/...
RUN unzip -q /tmp/plugins/menu-manager.zip -d ${CS2_DIR}/game/csgo/

# 7. cs2-WeaponPaints: zip top level is WeaponPaints/ (no addons/ prefix)
#    7a. plugin DLLs -> csgo/addons/counterstrikesharp/plugins/WeaponPaints/
RUN mkdir -p ${CS2_DIR}/game/csgo/addons/counterstrikesharp/plugins/WeaponPaints \
    && unzip -q /tmp/plugins/weapon-paints.zip "WeaponPaints/*" \
            -d ${CS2_DIR}/game/csgo/addons/counterstrikesharp/plugins/WeaponPaints-tmp \
    && mv ${CS2_DIR}/game/csgo/addons/counterstrikesharp/plugins/WeaponPaints-tmp/WeaponPaints/* \
          ${CS2_DIR}/game/csgo/addons/counterstrikesharp/plugins/WeaponPaints/ \
    && rm -rf ${CS2_DIR}/game/csgo/addons/counterstrikesharp/plugins/WeaponPaints-tmp
#    7b. gamedata -> csgo/addons/counterstrikesharp/gamedata/weaponpaints.json
RUN mkdir -p ${CS2_DIR}/game/csgo/addons/counterstrikesharp/gamedata \
    && unzip -q -j /tmp/plugins/weapon-paints.zip "gamedata/weaponpaints.json" \
            -d ${CS2_DIR}/game/csgo/addons/counterstrikesharp/gamedata/

# 8. Pre-baked configs (overlays defaults shipped by the plugins)
RUN mkdir -p ${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs/plugins/WeaponPaints \
    && cp -f /tmp/configs/core.json /tmp/configs/admins.json \
          ${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs/ \
    && cp -f /tmp/configs/plugins/WeaponPaints/WeaponPaints.json \
          ${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs/plugins/WeaponPaints/ \
    && mkdir -p ${CS2_DIR}/game/csgo/cfg/MatchZy \
    && cp -f /tmp/configs/cfg/MatchZy/config.cfg \
              /tmp/configs/cfg/MatchZy/admins.json \
              /tmp/configs/cfg/MatchZy/database.json \
          ${CS2_DIR}/game/csgo/cfg/MatchZy/ \
    && chown -R 1001:1001 ${CS2_DIR}/game/csgo/addons ${CS2_DIR}/game/csgo/cfg

# ---------- Stage 3: Runtime ----------
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    STEAMCMD_DIR=/opt/steamcmd \
    CS2_DIR=/opt/cs2 \
    CS2_APP_ID=730 \
    SERVERDATA=/opt/serverdata

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        lib32stdc++6 \
        libcurl4 \
        libsdl2-2.0-0 \
        libzstd1 \
        libnss3 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libcups2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libxrandr2 \
        libgbm1 \
        libpango-1.0-0 \
        libcairo2 \
        libasound2t64 \
        libxshmfence1 \
        locales \
        tini \
        tzdata \
    && useradd -m -u 1001 -s /bin/bash steam

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

COPY --from=with-plugins --chown=steam:steam ${STEAMCMD_DIR} ${STEAMCMD_DIR}
COPY --from=with-plugins --chown=steam:steam ${CS2_DIR}        ${CS2_DIR}
COPY --chown=steam:steam cs2/entrypoint.sh /entrypoint.sh
COPY --chown=steam:steam cs2/start_cs2.sh  ${CS2_DIR}/start_cs2.sh
RUN chmod +x /entrypoint.sh ${CS2_DIR}/start_cs2.sh

USER steam
WORKDIR ${SERVERDATA}

VOLUME ["/opt/serverdata"]

EXPOSE 27015/udp 27015/tcp 27020/udp 27005/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD pgrep -f "cs2" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["/opt/cs2/start_cs2.sh"]
