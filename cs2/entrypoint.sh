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

# ---- Prepare persistent dirs under /opt/serverdata ----
mkdir -p "${CSS_PERSIST}" \
         "${CSS_PERSIST}/plugins/WeaponPaints" \
         "${CFG_PERSIST}/MatchZy" \
         "${MAPS_PERSIST}" \
         "${SERVERDATA}/logs"

# ---- Seed CSS configs from image to persistent dir (one-way, only on first run) ----
if [ -d "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs" ] \
   && [ ! -L "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs" ]; then
    cp -rn "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs/." "${CSS_PERSIST}/" 2>/dev/null || true
fi

# ---- Seed csgo/cfg (server.cfg, MatchZy cfgs) from image to persistent dir ----
if [ -d "${CS2_DIR}/game/csgo/cfg" ] && [ ! -L "${CS2_DIR}/game/csgo/cfg" ]; then
    cp -rn "${CS2_DIR}/game/csgo/cfg/." "${CFG_PERSIST}/" 2>/dev/null || true
fi

# ---- Symlink image paths to persistent dirs ----
rm -rf "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs"
ln -sfn "${CSS_PERSIST}" "${CS2_DIR}/game/csgo/addons/counterstrikesharp/configs"

rm -rf "${CS2_DIR}/game/csgo/cfg"
ln -sfn "${CFG_PERSIST}" "${CS2_DIR}/game/csgo/cfg"

rm -rf "${CS2_DIR}/game/csgo/maps"
ln -sfn "${MAPS_PERSIST}" "${CS2_DIR}/game/csgo/maps"

# ---- Substitute env vars into plugin config files ----
substitute "${CSS_PERSIST}/admins.json"
substitute "${CSS_PERSIST}/plugins/WeaponPaints/WeaponPaints.json"
substitute "${CFG_PERSIST}/MatchZy/admins.json"
substitute "${CFG_PERSIST}/MatchZy/database.json"

# ---- Fix ownership (volume mounts can land as root) ----
chown -R steam:steam "${SERVERDATA}" 2>/dev/null || true
chown -R steam:steam "${CS2_DIR}/game/csgo/cfg" 2>/dev/null || true

# ---- Wait for MySQL (defensive; depends_on already gates startup) ----
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

# ---- Update CS2 (no-op if up to date) ----
echo "[entrypoint] Updating CS2 (app ${CS2_APP_ID})..."
${STEAMCMD_DIR}/steamcmd.sh \
    +force_install_dir "${CS2_DIR}" \
    +login anonymous \
    +app_update ${CS2_APP_ID} validate \
    +quit || echo "[entrypoint] WARN: steamcmd update failed, continuing"

exec "$@"
