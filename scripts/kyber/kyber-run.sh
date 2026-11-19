#!/bin/bash
# KYBER for AMP3 - server launcher.
# Does what the official image's /opt/kyber/entrypoint.sh does, using the
# runtime that kyber-install.sh placed in the shard, with settings from AMP.
#
# Usage: kyber-run.sh <FullBaseDir>
# Env (set by AMP): AMP_KYBER_* - see kyber.ampspec

set -uo pipefail
BASE="${1:?base dir missing}"; BASE="${BASE%/}"
log()  { echo "[KYBER] $*"; }
warn() { echo "[KYBER] WARNING: $*"; }
fail() { echo "[KYBER] ERROR: $*"; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

RUNTIME="$BASE/runtime/opt/kyber"
WINE="$BASE/wine/bin/wine64"
[ -x "$RUNTIME/kyber_cli" ] || fail "KYBER runtime is missing. Run Update first."
[ -x "$WINE" ] || fail "Wine is missing. Run Update first."

GAME_DIR="$(trim "${AMP_KYBER_GAME_DIR:-}")"; [ -z "$GAME_DIR" ] && GAME_DIR="$BASE/battlefront"
GAME_EXE="$(find "$GAME_DIR" -maxdepth 1 -iname 'starwarsbattlefrontii.exe' 2>/dev/null | head -n1)"
[ -n "$GAME_EXE" ] || fail "starwarsbattlefrontii.exe not found in $GAME_DIR. Set 'EA Token (game download)' and run Update, or upload the game there."

# ---------- accounts ----------
EA_EMAIL="$(trim "${AMP_KYBER_EA_EMAIL:-}")"
EA_PASS="${AMP_KYBER_EA_PASSWORD:-}"
[ -n "$EA_EMAIL" ] && [ -n "$EA_PASS" ] || fail "Set the EA account email and password (Kyber > Accounts)."
TOKEN="$(trim "${AMP_KYBER_TOKEN:-}")"
[ -n "$TOKEN" ] || fail "Set the KYBER token (Kyber > Accounts). Create one with 'kyber_cli get_token'."

# ---------- server info ----------
NAME="$(trim "${AMP_KYBER_SERVER_NAME:-}")"; [ -n "$NAME" ] || fail "Set a server name."
if [ "${#NAME}" -gt 24 ]; then warn "Server name is longer than 24 characters; truncating."; NAME="$(trim "${NAME:0:24}")"; fi
export KYBER_SERVER_NAME="$NAME"

DESC="${AMP_KYBER_SERVER_DESCRIPTION:-}"; DESC="${DESC//\\n/$'\n'}"
[ "${#DESC}" -gt 256 ] && { warn "Description longer than 256 characters; truncating."; DESC="${DESC:0:256}"; }
if [ -n "$DESC" ]; then export KYBER_SERVER_DESCRIPTION="$DESC"; else unset KYBER_SERVER_DESCRIPTION; fi

if [ -n "${AMP_KYBER_SERVER_PASSWORD:-}" ]; then export KYBER_SERVER_PASSWORD="$AMP_KYBER_SERVER_PASSWORD"; else unset KYBER_SERVER_PASSWORD; fi

MAXP="$(trim "${AMP_KYBER_MAX_PLAYERS:-40}")"
case "$MAXP" in ''|*[!0-9]*) MAXP=40 ;; esac
[ "$MAXP" -lt 1 ] && MAXP=1; [ "$MAXP" -gt 64 ] && MAXP=64
export KYBER_SERVER_MAX_PLAYERS="$MAXP"

# ---------- map rotation ----------
# Accepts the base64 string exported by the KYBER launcher, a JSON array,
# or a plain list of entries (one per line or comma separated).
ROT="${AMP_KYBER_MAP_ROTATION:-}"; ROT="$(trim "${ROT//\\n/$'\n'}")"
[ -n "$ROT" ] || fail "Set a map rotation (Kyber > Map Rotation)."
if [ "${ROT:0:1}" = "[" ]; then
  ROT_B64="$(printf '%s' "$ROT" | base64 -w0)"
elif DEC="$(printf '%s' "$ROT" | tr -d '[:space:]' | base64 -d 2>/dev/null)" && [ "${DEC:0:1}" = "[" ]; then
  ROT_B64="$(printf '%s' "$ROT" | tr -d '[:space:]')"
else
  ROT_B64="$(printf '%s\n' "$ROT" | tr ',' '\n' | jq -R 'gsub("^\\s+|\\s+$";"") | select(length>0)' | jq -sc . | tr -d '\n' | base64 -w0)"
fi
export KYBER_MAP_ROTATION="$ROT_B64"
log "Map rotation: $(printf '%s' "$ROT_B64" | base64 -d 2>/dev/null | head -c 400)"

# ---------- optional ----------
CHANNEL="$(trim "${AMP_KYBER_MODULE_CHANNEL:-default}")"
[ "$CHANNEL" = "custom" ] && CHANNEL="$(trim "${AMP_KYBER_MODULE_CHANNEL_CUSTOM:-}")"
if [ -n "$CHANNEL" ] && [ "$CHANNEL" != "default" ]; then export KYBER_MODULE_CHANNEL="$CHANNEL"; else unset KYBER_MODULE_CHANNEL; fi
export KYBER_LOG_LEVEL="$(trim "${AMP_KYBER_LOG_LEVEL:-info}")"

unset KYBER_MOD_FOLDER KYBER_SERVER_PLUGINS_PATH
if [ "${AMP_KYBER_USE_MODS:-false}" = "true" ]; then
  if [ -n "$(ls -A "$BASE/mods" 2>/dev/null)" ]; then
    export KYBER_MOD_FOLDER="$BASE/mods"; log "Loading mod collection from $KYBER_MOD_FOLDER"
  else
    warn "Mods are enabled but $BASE/mods is empty. Extract your exported collection (.tar) there with the File Manager."
  fi
fi
if [ "${AMP_KYBER_USE_PLUGINS:-false}" = "true" ]; then
  mkdir -p "$BASE/plugins"; export KYBER_SERVER_PLUGINS_PATH="$BASE/plugins"; log "Plugins folder: $KYBER_SERVER_PLUGINS_PATH"
fi

# ---------- runtime environment (mirrors the official image) ----------
export MAXIMA_DISABLE_WINE_VERIFICATION=1
export MAXIMA_WINE_COMMAND="$WINE"
export MAXIMA_DISABLE_QRC=1
export KYBER_BYPASS_DOCKER_I_REALLY_KNOW_WHAT_I_AM_DOING=1
export WINEPREFIX="$HOME/.local/share/maxima/wine/prefix"
export WINEDEBUG="${WINEDEBUG:--all}"
export LD_LIBRARY_PATH="$RUNTIME${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$WINEPREFIX"

cp -f "$HOME/.local/share/kyber/module/vivoxsdk.dll" "$GAME_DIR/" 2>/dev/null \
  || warn "could not copy vivoxsdk.dll into the game folder (voice chat may not work)"

if [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "Creating Wine prefix (first start only, can take a minute) ..."
  "$WINE" wineboot --init >/dev/null 2>&1 || warn "wineboot reported an error; continuing"
fi

args=(./kyber_cli start_server --show-console
      --credentials="${EA_EMAIL}:${EA_PASS}"
      --token "$TOKEN"
      --game-path "$GAME_EXE"
      --verbose)
[ "${AMP_KYBER_MAXIMA_DEBUG:-false}" = "true" ] && args+=(--debug)

log "Starting KYBER server '$KYBER_SERVER_NAME' (max $KYBER_SERVER_MAX_PLAYERS players)"
cd "$RUNTIME" || fail "cannot enter $RUNTIME"
exec "${args[@]}"
