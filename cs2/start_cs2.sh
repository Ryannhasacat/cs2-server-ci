#!/usr/bin/env bash
set -euo pipefail

CS2_DIR=${CS2_DIR:-/opt/cs2}
SERVERDATA=${SERVERDATA:-/opt/serverdata}

# ---- Tunables (override via docker-compose env) ----
: "${CS2_PORT:=27015}"
: "${CS2_TICKRATE:=64}"
: "${CS2_MAXPLAYERS:=10}"
: "${CS2_MAP:=de_dust2}"
: "${CS2_GAMEMODE:=competitive}"
: "${CS2_RCON_PASSWORD:=changeme-rcon}"
: "${CS2_SERVER_PASSWORD:=}"
: "${CS2_HOTNAME:=CS2 Dedicated Server}"
: "${CS2_REGION:=3}"
: "${CS2_LAN:=0}"
: "${CS2_TV_ENABLE:=1}"
: "${CS2_TV_PORT:=27020}"
: "${CS2_TV_DELAY:=0}"
: "${CS2_AUTHKEY:=}"
: "${CS2_GSLT:=}"
: "${CS2_HOST_WORKSHOP_MAP:=}"
: "${CS2_WORKSHOP_COLLECTION:=}"
: "${CS2_EXTRA_ARGS:=}"

cd "${CS2_DIR}/game/bin/linux"

ARGS=(
    ./cs2
    -dedicated
    -console
    -usercon
    -port "${CS2_PORT}"
    -tickrate "${CS2_TICKRATE}"
    -maxplayers "${CS2_MAXPLAYERS}"
    -map "${CS2_MAP}"
    -game csgo
    -authkey "${CS2_AUTHKEY}"
    -rcon_password "${CS2_RCON_PASSWORD}"
    -hostname "${CS2_HOTNAME}"
    -region "${CS2_REGION}"
    -exec server.cfg
)

# GSLT only when set (empty = LAN / direct-IP only)
[ -n "${CS2_GSLT}" ] && ARGS+=( +sv_setsteamaccount "${CS2_GSLT}" )

[ "${CS2_TV_ENABLE}" = "1" ] && ARGS+=( -tv_enable 1 -tv_port "${CS2_TV_PORT}" -tv_delay "${CS2_TV_DELAY}" -tv_relay )
[ "${CS2_LAN}" = "1" ]       && ARGS+=( -lan )
[ -n "${CS2_SERVER_PASSWORD}" ] && ARGS+=( +sv_password "${CS2_SERVER_PASSWORD}" )

# Workshop
if [ -n "${CS2_WORKSHOP_COLLECTION}" ]; then
    ARGS+=( +host_workshop_collection "${CS2_WORKSHOP_COLLECTION}" )
elif [ -n "${CS2_HOST_WORKSHOP_MAP}" ]; then
    ARGS+=( +host_workshop_map "${CS2_HOST_WORKSHOP_MAP}" )
fi

if [ -n "${CS2_EXTRA_ARGS}" ]; then
    # shellcheck disable=SC2206
    EXTRA=( ${CS2_EXTRA_ARGS} )
    ARGS+=( "${EXTRA[@]}" )
fi

echo "[start_cs2] exec: ${ARGS[*]}"
exec "${ARGS[@]}"
