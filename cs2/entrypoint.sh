#!/usr/bin/env bash
set -euo pipefail

STEAMCMD_DIR=${STEAMCMD_DIR:-/opt/steamcmd}
CS2_DIR=${CS2_DIR:-/opt/cs2}
CS2_APP_ID=${CS2_APP_ID:-730}
SERVERDATA=${SERVERDATA:-/opt/serverdata}

CSS_PERSIST="${SERVERDATA}/counterstrikesharp-configs"
CFG_PERSIST="${SERVERDATA}/csgo/cfg"
MAPS_PERSIST="${SERVERDATA}/csgo/maps"

# ---- envsubst helper (avoid depending on gettext envsubst binary) ----
substitute() {
    local file="$1"
    [ -f "$file" ] || return 0
    sed -i \
        -e "s|__CS2_ADMIN_STEAMID__|${CS2_ADMIN_STEAMID:-}|g" \
        -e "s|__CS2_MYSQL_HOST__|${CS2_MYSQL_HOST:-mysql}|g" \
        -e "s|__CS2_MYSQL_PORT__|${CS2_MYSQL_PORT:-3306}|g" \
        -e "s|__CS2_MYSQL_USER__|${CS2_MYSQL_USER:-cs2}|g" \
        -e "s|__CS2_MYSQL_PASS__|${CS2_MYSQL_PASS:-}|g" \
        -e "s|__CS2_MYSQL_DB_WEAPON__|${CS2_MYSQL_DB_WEAPON:-weaponpaints}|g" \
        -e "s|__CS2_MYSQL_DB_MATCH__|${CS2_MYSQL_DB_MATCH:-matchzy}|g" \
        "$file"
}

# ============================================================
# Step 1: Ensure CS2 game files are installed.
#   - On FIRST container start: /opt/cs2 is empty (or only has addons/cfg from image).
#     Download full CS2 via SteamCMD (~20-30 min, ~30 GB).
#   - On subsequent starts: validate-only (delta update, ~1-2 min if CS2 is patched).
#   - /opt/cs2 is a NAMED VOLUME — persists across container recreations.
# ============================================================
ensure_cs2_installed() {
    # If game binary already exists, do a quick validate.
    if [ -x "${CS2_DIR}/game/bin/linux/cs2" ]; then
        echo "[entrypoint] CS2 already installed at ${CS2_DIR}; running validate..."
        ${STEAMCMD_DIR}/steamcmd.sh \
            +force_install_dir "${CS2_DIR}" \
            +login anonymous \
            +app_update ${CS2_APP_ID} validate \
            +quit || echo "[entrypoint] WARN: steamcmd validate failed, continuing"
        return
    fi

    echo "[entrypoint] CS2 not found at ${CS2_DIR}; downloading via SteamCMD..."
    echo "[entrypoint] This takes 20-30 minutes on first run; subsequent starts use cached volume."

    ${STEAMCMD_DIR}/steamcmd.sh \
        +force_install_dir "${CS2_DIR}" \
        +login anonymous \
        +app_update ${CS2_APP_ID} validate \
        +quit || {
            echo "[entrypoint] ERROR: SteamCMD failed to install CS2"
            echo "  Check network connectivity to steamcdn-a.akamaihd.net"
            exit 1
        }
}

ensure_cs2_installed

# ============================================================
# Step 2: Prepare persistent dirs under /opt/serverdata.
# ============================================================
mkdir -p "${CSS_PERSIST}" \
         "${CSS_PERSIST}/plugins/WeaponPaints" \
         "${CFG_PERSIST}/MatchZy" \
         "${MAPS_PERSIST}" \
         "${SERVERDATA}/logs"

# ============================================================
# Step 3: Symlink image addons/cfg into persistent dirs.
#   Plugins under csgo/addons/ are baked into the image at build time.
#   Configs under csgo/cfg/ are also baked in.
#   We re-bind both onto the persistent volume so user can edit configs.
# ============================================================
# CSS configs (admins.json, core.json, WeaponPaints/...) — seed once
if [ -d "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs" ] \
   && [ ! -L "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs" ]; then
    cp -rn "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs/." "${CSS_PERSIST}/" 2>/dev/null || true
fi
rm -rf "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs"
ln -sfn "${CSS_PERSIST}" "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs"

# MatchZy cfg (warmup/knife/live/prac + config.cfg + admins + database)
if [ -d "${CS2_DIR}/game/csgo/cfg" ] && [ ! -L "${CS2_DIR}/game/csgo/cfg" ]; then
    cp -rn "${CS2_DIR}/game/csgo/cfg/." "${CFG_PERSIST}/" 2>/dev/null || true
fi
rm -rf "${CS2_DIR}/game/csgo/cfg"
ln -sfn "${CFG_PERSIST}" "${CS2_DIR}/game/csgo/cfg"

# Maps
if [ -d "${CS2_DIR}/game/csgo/maps" ] && [ ! -L "${CS2_DIR}/game/csgo/maps" ]; then
    cp -rn "${CS2_DIR}/game/csgo/maps/." "${MAPS_PERSIST}/" 2>/dev/null || true
fi
rm -rf "${CS2_DIR}/game/csgo/maps"
ln -sfn "${MAPS_PERSIST}" "${CS2_DIR}/game/csgo/maps"

# ============================================================
# Step 4: Substitute env vars into plugin config files.
# ============================================================
substitute "${CSS_PERSIST}/admins.json"
substitute "${CSS_PERSIST}/plugins/WeaponPaints/WeaponPaints.json"
substitute "${CFG_PERSIST}/MatchZy/admins.json"
substitute "${CFG_PERSIST}/MatchZy/database.json"

# ============================================================
# Step 5: Fix ownership (volume mounts can land as root).
# ============================================================
chown -R steam:steam "${SERVERDATA}" 2>/dev/null || true
chown -R steam:steam "${CS2_DIR}/game/csgo/cfg" 2>/dev/null || true

# ============================================================
# Step 6: Wait for MySQL (defensive; depends_on already gates startup).
# ============================================================
if command -v mysqladmin >/dev/null 2>&1; then
    echo "[entrypoint] Waiting for MySQL ${CS2_MYSQL_HOST:-mysql}:${CS2_MYSQL_PORT:-3306}..."
    for i in $(seq 1 30); do
        if mysqladmin ping -h "${CS2_MYSQL_HOST:-mysql}" -P "${CS2_MYSQL_PORT:-3306}" \
               -u "${CS2_MYSQL_USER:-cs2}" -p"${CS2_MYSQL_PASS:-}" --connect-timeout=2 >/dev/null 2>&1; then
            echo "[entrypoint] MySQL ready"
            break
        fi
        sleep 2
    done
fi

exec "$@"
