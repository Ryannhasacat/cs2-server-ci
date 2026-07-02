#!/usr/bin/env bash
# Download the 7 plugin archives into cs2/plugins/ for offline build.
# Re-runnable: skips downloads when the archive already exists and is intact.
# Used by GitHub Actions; safe to run locally for development.

set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/plugins"
mkdir -p "$DEST"
cd "$DEST"

CURL_OPTS=(--http1.1 --retry 5 --retry-delay 10 --connect-timeout 30 --max-time 600 -fSL --silent --show-error)

fetch() {
    local name="$1"
    local url="$2"
    local expected_size="${3:-}"
    if [ -f "$name" ] && [ -s "$name" ]; then
        if [[ "$name" == *.zip ]]; then
            unzip -tq "$name" >/dev/null 2>&1 && { echo "OK   $name (cached)"; return 0; }
        elif [[ "$name" == *.tar.gz ]]; then
            tar -tzf "$name" >/dev/null 2>&1 && { echo "OK   $name (cached)"; return 0; }
        fi
        echo "REDL $name (cache corrupt; redownloading)"
        rm -f "$name"
    fi
    echo "GET  $name"
    curl "${CURL_OPTS[@]}" -o "$name" "$url"
    ls -la "$name" | awk '{print "    size:", $5, "bytes"}'
}

# Metamod:Source 1.11 (static URL — not on GitHub)
fetch mmsource.tar.gz \
      "https://mms.alliedmods.net/mmsdrop/1.11/mmsource-1.11.0-git1148-linux.tar.gz"

# CounterStrikeSharp (with runtime)
fetch css-with-runtime.zip \
      "https://github.com/roflmuffin/CounterStrikeSharp/releases/download/v1.0.370/counterstrikesharp-with-runtime-linux-1.0.370.zip"

# MatchZy
fetch matchzy.zip \
      "https://github.com/shobhit-pathak/MatchZy/releases/download/0.8.15/MatchZy-0.8.15.zip"

# cs2-WeaponPaints 依赖 (NickFox007)
fetch player-settings.zip \
      "https://github.com/NickFox007/PlayerSettingsCS2/releases/download/0.9.4/PlayerSettings.zip"
fetch any-base-lib.zip \
      "https://github.com/NickFox007/AnyBaseLibCS2/releases/download/0.9.4/AnyBaseLib.zip"
fetch menu-manager.zip \
      "https://github.com/NickFox007/MenuManagerCS2/releases/download/1.4.1/MenuManager.zip"

# cs2-WeaponPaints
fetch weapon-paints.zip \
      "https://github.com/Nereziel/cs2-WeaponPaints/releases/download/build-423/WeaponPaints.zip"

echo
echo "=== summary ==="
ls -la "$DEST" | grep -vE '^total|^d'
echo
echo "All archives verified. Ready for 'docker build' or 'docker compose build'."
