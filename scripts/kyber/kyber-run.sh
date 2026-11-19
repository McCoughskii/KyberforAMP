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
# AMP checkboxes do not arrive as a plain "true": depending on the AMP version the
# value is "True", the EnumValues entry ("setting.X.value.True") or its label.
is_true() { case "$(trim "${1:-}" | tr '[:upper:]' '[:lower:]')" in true|1|yes|on|enabled|*.true) return 0 ;; *) return 1 ;; esac; }

RUNTIME="$BASE/runtime/opt/kyber"
WINE="$BASE/wine/bin/wine64"
[ -x "$RUNTIME/kyber_cli" ] || fail "KYBER runtime is missing. Run Update first."
[ -x "$WINE" ] || fail "Wine is missing. Run Update first."

GAME_DIR="$(trim "${AMP_KYBER_GAME_DIR:-}")"; [ -z "$GAME_DIR" ] && GAME_DIR="$BASE/battlefront"
GAME_EXE="$(find "$GAME_DIR" -maxdepth 1 -iname 'starwarsbattlefrontii.exe' 2>/dev/null | head -n1)"
[ -n "$GAME_EXE" ] || fail "starwarsbattlefrontii.exe not found in $GAME_DIR. Set 'EA Token (game download)' and run Update, or upload the game there."

# ---------- accounts ----------
EA_TOKEN="$(trim "${AMP_KYBER_EA_TOKEN:-}")"
[ -n "$EA_TOKEN" ] || fail "Set the EA token (Kyber > Accounts). Create one with 'kyber_cli get_ea_token'."
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
# kyber_cli expects KYBER_MAP_ROTATION = base64 of "mode;map" lines (see
# CLI/lib/commands/start_server_command.dart). Accepted here:
#   - the base64 string from the KYBER launcher's Export (used as-is)
#   - plain "mode;map" lines
#   - the launcher's JSON export: [{"mode": "...", "map": "..."}]
ROT="${AMP_KYBER_MAP_ROTATION:-}"; ROT="$(trim "${ROT//\\n/$'\n'}")"
[ -n "$ROT" ] || fail "Set a map rotation (Kyber > Map Rotation)."
if [ "${ROT:0:1}" = "[" ]; then
  LINES="$(printf '%s' "$ROT" | jq -r '.[] | "\(.mode);\(.map)"')" || fail "Map rotation JSON is not valid."
elif [[ "$ROT" == *";"* ]]; then
  LINES="$ROT"
else
  LINES="$(printf '%s' "$ROT" | tr -d '[:space:]' | base64 -d 2>/dev/null)" \
    || fail "Map rotation is not valid base64. Paste the string from the KYBER launcher's Export, or 'mode;map' lines."
fi
LINES="$(printf '%s\n' "$LINES" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
count=0; n=0
while IFS= read -r line; do
  n=$((n + 1))
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] && continue
  [ "$(printf '%s' "$line" | tr -cd ';' | wc -c)" -eq 1 ] \
    || fail "Map rotation entry $n is not in 'mode;map' form: $line"
  count=$((count + 1))
done <<< "$LINES"
[ "$count" -gt 0 ] || fail "Map rotation has no entries."
export KYBER_MAP_ROTATION="$(printf '%s' "$LINES" | base64 -w0)"
log "Map rotation: $count entries"
while IFS= read -r line; do [ -n "$line" ] && [ "${line:0:1}" != "#" ] && log "  $line"; done <<< "$LINES"

# ---------- optional ----------
CHANNEL="$(trim "${AMP_KYBER_MODULE_CHANNEL:-default}")"
[ "$CHANNEL" = "custom" ] && CHANNEL="$(trim "${AMP_KYBER_MODULE_CHANNEL_CUSTOM:-}")"
if [ -n "$CHANNEL" ] && [ "$CHANNEL" != "default" ]; then export KYBER_MODULE_CHANNEL="$CHANNEL"; else unset KYBER_MODULE_CHANNEL; fi
export KYBER_LOG_LEVEL="$(trim "${AMP_KYBER_LOG_LEVEL:-info}")"

unset KYBER_MOD_FOLDER KYBER_SERVER_PLUGINS_PATH
if is_true "${AMP_KYBER_USE_MODS:-}"; then
  MODS="$BASE/mods"; mkdir -p "$MODS"
  # An uploaded launcher export (.tar/.tar.gz/.tgz/.zip) in mods/ replaces the
  # current collection: unpack it, keep the old one in mods-previous/.
  shopt -s nullglob nocaseglob
  archives=("$MODS"/*.tar "$MODS"/*.tar.gz "$MODS"/*.tgz "$MODS"/*.zip)
  shopt -u nullglob nocaseglob
  if [ "${#archives[@]}" -gt 0 ]; then
    newest="$(ls -t "${archives[@]}" | head -n1)"
    log "Installing mod collection from $(basename "$newest") ..."
    mkdir -p "$BASE/mod-archives"
    for a in "${archives[@]}"; do mv -f "$a" "$BASE/mod-archives/"; done
    newest="$BASE/mod-archives/$(basename "$newest")"
    rm -rf "$BASE/mods-previous"; mv "$MODS" "$BASE/mods-previous"; mkdir -p "$MODS"
    case "${newest,,}" in
      *.zip) python3 -m zipfile -e "$newest" "$MODS" ;;
      *)     tar -xf "$newest" -C "$MODS" --no-same-owner ;;
    esac || fail "could not unpack $(basename "$newest") (the previous collection is in mods-previous)."
    log "Mod collection unpacked; previous collection kept in mods-previous/."
  fi
  # kyber_cli wants a folder holding exactly one .kbcollection file plus its mods.
  mapfile -t collections < <(find "$MODS" -maxdepth 3 -type f -iname '*.kbcollection' 2>/dev/null)
  if [ "${#collections[@]}" -eq 1 ]; then
    export KYBER_MOD_FOLDER="$(dirname "${collections[0]}")"
    log "Loading mod collection $(basename "${collections[0]}" .kbcollection) ($(du -sh "$KYBER_MOD_FOLDER" 2>/dev/null | cut -f1))"
  elif [ "${#collections[@]}" -gt 1 ]; then
    fail "mods/ contains more than one collection: $(printf '%s ' "${collections[@]##*/}"). Keep only one."
  else
    warn "Mods are enabled but no collection was found. In the KYBER launcher use Play > Export Collection (tar) and upload the .tar into the mods folder."
  fi
else
  log "Mod collection disabled (Load Mod Collection = '${AMP_KYBER_USE_MODS:-}')."
fi
if is_true "${AMP_KYBER_USE_PLUGINS:-}"; then
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

# With an EA token session kyber_cli launches the game in "Online" mode, where
# maxima only treats the game as installed if the registry entry the game's own
# installer (touchup) would write is present. That installer cannot run headless,
# so register the install ourselves (same key as __Installer/installerdata.xml).
WIN_GAME_DIR="Z:$(printf '%s' "${GAME_DIR%/}" | tr '/' '\\')\\"
for view in 64 32; do
  "$WINE" reg add 'HKLM\Software\EA Games\STAR WARS Battlefront II' /v 'Install Dir' /d "$WIN_GAME_DIR" /f "/reg:$view" >/dev/null 2>&1 \
    && "$WINE" reg add 'HKLM\Software\EA Games\STAR WARS Battlefront II' /v 'Locale' /d 'en_US' /f "/reg:$view" >/dev/null 2>&1 \
    || warn "could not register the game install in the Wine registry (view $view)"
done
log "Registered game install: $WIN_GAME_DIR"

# No --credentials: start_server has no EA-token option, so the EA login relies on
# the session/licence maxima keeps from the token-based game download.
args=(./kyber_cli start_server --show-console
      --token "$TOKEN"
      --game-path "$GAME_EXE")
# --verbose echoes every argument, KYBER token included, so only use it when asked.
case "$KYBER_LOG_LEVEL" in debug|trace) args+=(--verbose) ;; esac
is_true "${AMP_KYBER_MAXIMA_DEBUG:-}" && args+=(--debug)

# ---------- KYBER API bridge (console commands + admins) ----------
# kyber_cli does not read stdin, so commands typed in the AMP console are sent
# to the server through the KYBER API (ServerManagement.RunCommand), the same
# way the KYBER launcher does it. Admins are KYBER moderators, also set via the API.
API="$BASE/scripts/kyber-api.py"
export KYBER_TOKEN="$TOKEN" KYBER_EA_TOKEN="$EA_TOKEN" KYBER_STATE_DIR="$BASE/.kyber-api"
rm -f "$KYBER_STATE_DIR/api-state.json"   # server id changes on every start

ADMINS=()
while IFS= read -r a; do a="$(trim "$a")"; [ -n "$a" ] && ADMINS+=("$a"); done \
  < <(printf '%s\n' "${AMP_KYBER_ADMINS:-}" | sed 's/\\n/\n/g' | tr ',' '\n')

log "Starting KYBER server '$KYBER_SERVER_NAME' (max $KYBER_SERVER_MAX_PLAYERS players)"
cd "$RUNTIME" || fail "cannot enter $RUNTIME"
# Job control gives kyber_cli its own process group; without it bash would start
# the background job with SIGINT ignored and AMP's Stop could not reach it.
set -m
"${args[@]}" < /dev/null &
kpid=$!
set +m

stopping=0
stop_server() {
  [ "$stopping" = 1 ] && return; stopping=1
  log "Stopping KYBER server ..."
  kill -INT "$kpid" 2>/dev/null
  for _ in $(seq 1 10); do kill -0 "$kpid" 2>/dev/null || return; sleep 1; done
  # kyber_cli waits for the game; end the game (every Wine process in this prefix).
  log "Closing the game ..."
  "$BASE/wine/bin/wineserver" -k >/dev/null 2>&1
  for _ in $(seq 1 15); do kill -0 "$kpid" 2>/dev/null || return; sleep 1; done
  kill -TERM "$kpid" 2>/dev/null; sleep 3; kill -KILL "$kpid" 2>/dev/null
  "$BASE/wine/bin/wineserver" -k9 >/dev/null 2>&1
}
trap stop_server INT TERM HUP

if [ -f "$API" ] && command -v python3 >/dev/null; then
  # Admin sync once the server has registered (waits up to 5 minutes).
  (
    sync_args=()
    is_true "${AMP_KYBER_ADMINS_EXCLUSIVE:-}" && sync_args+=(--remove-others)
    if [ "${#ADMINS[@]}" -gt 0 ] || [ "${#sync_args[@]}" -gt 0 ]; then
      KYBER_WAIT=300 python3 "$API" sync-admins "${sync_args[@]}" "${ADMINS[@]}"
    fi
  ) &
  # Forward console input. A leading "/" is optional, as in the KYBER launcher.
  # "admins" lists the current admins instead of being sent to the server.
  # The AMP3 preview can deliver one console line several times in a row, so an
  # identical line within 3 seconds of the previous one is ignored.
  last_line=""; last_at=0
  while kill -0 "$kpid" 2>/dev/null; do
    if IFS= read -r -t 1 line; then
      line="$(trim "$line")"; [ -z "$line" ] && continue
      now="$(date +%s%N)"; now=$((now / 1000000))
      if [ "$line" = "$last_line" ] && [ $((now - last_at)) -lt 3000 ]; then continue; fi
      last_line="$line"; last_at="$now"
      log "> $line"
      case "$line" in
        admins|/admins) python3 "$API" admins ;;
        *) python3 "$API" run "$line" ;;
      esac
      now="$(date +%s%N)"; last_at=$((now / 1000000))   # window counts from when we finished
    else
      rc=$?; [ "$rc" -le 128 ] && sleep 1   # EOF (no console attached): don't spin
    fi
  done
else
  warn "kyber-api.py or python3 missing: console commands and admins are disabled."
fi
wait "$kpid"; rc=$?
log "KYBER server exited with code $rc"
exit "$rc"
