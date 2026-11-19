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
[ -n "$GAME_EXE" ] || fail "starwarsbattlefrontii.exe not found in $GAME_DIR. Set 'EA Token (game download only)' and run Update, or upload the game there."

# ---------- accounts ----------
# The server logs in to EA with the account's email (or EA ID) and password,
# like the official image's MAXIMA_CREDENTIALS, so it does not depend on a
# saved maxima session or an EA token that expires.
EA_USER="$(trim "${AMP_KYBER_EA_EMAIL:-}")"
EA_PASS="${AMP_KYBER_EA_PASSWORD:-}"
[ -n "$EA_USER" ] && [ -n "$EA_PASS" ] || fail "Set the EA email and EA password (Kyber > Accounts) for the account that owns Star Wars Battlefront II."
[[ "$EA_USER" == *:* ]] && fail "The EA email/EA ID cannot contain ':'."
EA_TOKEN="$(trim "${AMP_KYBER_EA_TOKEN:-}")"
TOKEN="$(trim "${AMP_KYBER_TOKEN:-}")"
[ -n "$TOKEN" ] || fail "Set the KYBER token (Kyber > Accounts). Create one with 'kyber_cli get_token'."

# Everything this script and its children print reaches the AMP console, and
# kyber_cli --verbose (Log Level debug/trace) echoes its arguments. Replace the
# EA login and tokens with **** on the way out. A bash read loop, not awk: the
# container's mawk buffers piped input, which held console lines back. The
# filter ignores AMP's stop signals so it can still pass on the shutdown
# messages; it ends at EOF. It also swallows the built-in plugin's heartbeat
# lines, touching $HEARTBEAT instead so the crash watchdog can spot a frozen game.
# It also remembers who is connected and, when the server ends (a crash
# included), prints a "left" line for each of them. Without those lines AMP's
# agent keeps that run's players and shows them as connected next to the next
# run's real list, so the Connected Users count flips between the two.
WATCH_DIR="$BASE/.watchdog"
HEARTBEAT="$WATCH_DIR/heartbeat"
rm -rf "$WATCH_DIR"; mkdir -p "$WATCH_DIR"
exec > >(
  trap '' INT TERM HUP
  secrets=()
  for s in "$EA_PASS" "$TOKEN" "$EA_TOKEN" "$EA_USER"; do [ "${#s}" -ge 4 ] && secrets+=("$s"); done
  declare -A online=()   # player id -> name, from the built-in plugin's join/leave lines
  user_re='\[KYBER\] \[info\] \[AMP\] (.+) \(([0-9]+)\) (joined|left) the server$'
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"   # the game's output ends lines with CRLF; AMP's regexes expect none
    if [[ "$line" == *"[KYBER] [info] [AMP] heartbeat" ]]; then : > "$HEARTBEAT"; continue; fi
    if [[ "$line" =~ $user_re ]]; then
      if [ "${BASH_REMATCH[3]}" = joined ]; then online["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1]}"
      else unset 'online[${BASH_REMATCH[2]}]'; fi
    fi
    for s in "${secrets[@]}"; do line="${line//"$s"/****}"; done
    printf '%s\n' "$line"
  done
  for id in "${!online[@]}"; do
    printf '[KYBER] [info] [AMP] %s (%s) left the server\n' "${online[$id]}" "$id"
  done
) 2>&1
CENSOR_PID=$!

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

# ---------- mods, plugins and module options ----------
CHANNEL="$(trim "${AMP_KYBER_MODULE_CHANNEL:-default}")"
[ "$CHANNEL" = "custom" ] && CHANNEL="$(trim "${AMP_KYBER_MODULE_CHANNEL_CUSTOM:-}")"
if [ -n "$CHANNEL" ] && [ "$CHANNEL" != "default" ]; then export KYBER_MODULE_CHANNEL="$CHANNEL"; else unset KYBER_MODULE_CHANNEL; fi
export KYBER_LOG_LEVEL="$(trim "${AMP_KYBER_LOG_LEVEL:-info}")"

# Builds a KYBER .kbcollection (a zip holding METADATA, the format of
# Packages/kyber_collection/lib/src/mod_collection.dart) that lists one Frosty
# .fbcollection and its mods. Usage: make_kbcollection <file.fbcollection>
make_kbcollection() {
  python3 - "$1" <<'PY'
import io, json, os, struct, sys, uuid, zipfile
src = sys.argv[1]
with open(src, "rb") as f:
    magic, _ver, off, size = struct.unpack("<4I", f.read(16))
    if magic != 0x46434F4C:
        sys.exit("not a Frosty collection file")
    f.seek(off)
    man = json.loads(f.read(size).decode("utf-8"))
folder = os.path.dirname(os.path.abspath(src))
mods = [m.replace("\\", "/") for m in man.get("mods", [])]
missing = [m for m in mods if not os.path.isfile(os.path.join(folder, os.path.basename(m)))]
if missing:
    sys.exit("missing mod files: " + ", ".join(missing))
title = (man.get("title") or os.path.splitext(os.path.basename(src))[0])[:255]
def term(s): return s.encode("latin-1", "replace") + b"\0"
def sized(s):
    b = s.encode("latin-1", "replace")[:255]
    return bytes([len(b)]) + b
meta = io.BytesIO()
meta.write(struct.pack("<I", 1))                      # collection version
meta.write(term(uuid.uuid4().hex))                    # localId
meta.write(sized(title)); meta.write(sized(""))       # title, description
meta.write(struct.pack("<I", 0))                      # isCosmetic
meta.write(struct.pack("<I", 1))                      # one entry: the Frosty collection
for v in (title, man.get("version") or "", man.get("link") or "",
          os.path.basename(src), "true", ",".join(os.path.basename(m) for m in mods)):
    meta.write(term(v))
out = os.path.join(folder, os.path.splitext(os.path.basename(src))[0] + ".kbcollection")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("METADATA", meta.getvalue())
print("%s|%d" % (os.path.basename(out), len(mods)))
PY
}

unset KYBER_MOD_FOLDER KYBER_SERVER_PLUGINS_PATH KYBER_DEV_PLUGIN_PATH
if is_true "${AMP_KYBER_USE_MODS:-}"; then
  # kyber_cli loads the collection straight from KYBER_MOD_FOLDER: put the
  # collection file and all of its mods directly in mods/. It needs a
  # .kbcollection there; if there is only a Frosty .fbcollection, one is made
  # from it once (replace it with the launcher's own any time).
  # A folder is usable if it has a .kbcollection, or a .fbcollection next to its
  # .fbmod files. Older versions of this template used mods-previous/, so fall
  # back to it while mods/ has no usable collection.
  has_collection() {
    compgen -G "$1/*.kbcollection" >/dev/null && return 0
    compgen -G "$1/*.fbcollection" >/dev/null && compgen -G "$1/*.fbmod" >/dev/null
  }
  export KYBER_MOD_FOLDER="$BASE/mods"
  if ! has_collection "$BASE/mods" && has_collection "$BASE/mods-previous"; then
    KYBER_MOD_FOLDER="$BASE/mods-previous"
    log "No collection in mods/, using the one in mods-previous/ (move it into mods/ any time)."
  fi
  mkdir -p "$KYBER_MOD_FOLDER"
  shopt -s nullglob; kb=("$KYBER_MOD_FOLDER"/*.kbcollection); fb=("$KYBER_MOD_FOLDER"/*.fbcollection); shopt -u nullglob
  if [ "${#kb[@]}" -eq 0 ] && [ "${#fb[@]}" -eq 1 ]; then
    made="$(make_kbcollection "${fb[0]}")" || fail "could not build a .kbcollection from $(basename "${fb[0]}")."
    log "Created ${made%|*} (${made##*|} mods) from $(basename "${fb[0]}")"
  fi
  log "Mod folder: $KYBER_MOD_FOLDER"
else
  log "Mod collection disabled (Load Mod Collection = '${AMP_KYBER_USE_MODS:-}')."
fi
if is_true "${AMP_KYBER_USE_PLUGINS:-}"; then
  mkdir -p "$BASE/plugins"; export KYBER_SERVER_PLUGINS_PATH="$BASE/plugins"; log "Plugins folder: $KYBER_SERVER_PLUGINS_PATH"
fi

# KYBER sends player joins, leaves and chat only to the KYBER API, never to the
# console, so AMP's user list stays empty. This small built-in plugin prints them
# as "[KYBER] [info] [AMP] ..." lines for the UserJoin/Leave/Chat regexes.
# It loads through KYBER_DEV_PLUGIN_PATH, separate from the plugins folder.
if is_true "${AMP_KYBER_TRACK_PLAYERS:-true}"; then
  AMP_PLUGIN="$BASE/.amp-plugin"
  mkdir -p "$AMP_PLUGIN/server"
  printf '{ "name": "AMP", "minVersion": "2.0.0" }\n' > "$AMP_PLUGIN/plugin.json"
  cat > "$AMP_PLUGIN/server/__init__.lua" <<'LUA'
local function id(p) return string.format("%d", p.playerId or 0) end
EventManager.Listen("ServerPlayer:Joined", function(p)
    if not p.isBot then print(p.name .. " (" .. id(p) .. ") joined the server") end
end)
EventManager.Listen("ServerPlayer:Disconnect", function(p)
    if not p.isBot then print(p.name .. " (" .. id(p) .. ") left the server") end
end)
EventManager.Listen("ServerPlayer:SendMessage", function(p, msg)
    if p and not p.isBot then print("chat " .. p.name .. ": " .. tostring(msg)) end
end)
-- Heartbeat every 30 s of server time; the run script's crash watchdog uses it
-- to notice a frozen game. The console filter hides these lines.
local sinceBeat = 0
EventManager.Listen("Server:UpdatePre", function(dt)
    sinceBeat = sinceBeat + dt
    if sinceBeat >= 30 then sinceBeat = 0; print("heartbeat") end
end)
LUA
  export KYBER_DEV_PLUGIN_PATH="Z:$(printf '%s' "$AMP_PLUGIN" | tr '/' '\\')"
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
WINESERVER="$BASE/wine/bin/wineserver"

# The game runs under Wine as a child of kyber_cli but outlives it if kyber_cli
# is stopped directly (AMP's Restart does that). A leftover game keeps port
# 25200 and its KYBER registration, so close it before starting and whenever
# kyber_cli ends. ("[i]" keeps this grep from matching its own command line.)
game_running() { grep -qsai 'starwarsbattlefront[i]i' /proc/[0-9]*/cmdline; }
close_game() {
  "$WINESERVER" -k >/dev/null 2>&1
  for _ in $(seq 1 15); do game_running || return 0; sleep 1; done
  "$WINESERVER" -k9 >/dev/null 2>&1; sleep 2
  ! game_running
}
if game_running; then
  log "Closing a game left running by the previous start ..."
  close_game || fail "a game from the previous start is still running. Use Stop, wait for Stopped, then Start."
fi

cp -f "$HOME/.local/share/kyber/module/vivoxsdk.dll" "$GAME_DIR/" 2>/dev/null \
  || warn "could not copy vivoxsdk.dll into the game folder (voice chat may not work)"

if [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "Creating Wine prefix (first start only, can take a minute) ..."
  "$WINE" wineboot --init >/dev/null 2>&1 || warn "wineboot reported an error; continuing"
fi

# Maxima launches the game in "Online" mode, where it only treats the game as
# installed if the registry entry the game's own installer (touchup) would write
# is present. That installer cannot run headless, so register the install
# ourselves (same key as __Installer/installerdata.xml).
WIN_GAME_DIR="Z:$(printf '%s' "${GAME_DIR%/}" | tr '/' '\\')\\"
for view in 64 32; do
  "$WINE" reg add 'HKLM\Software\EA Games\STAR WARS Battlefront II' /v 'Install Dir' /d "$WIN_GAME_DIR" /f "/reg:$view" >/dev/null 2>&1 \
    && "$WINE" reg add 'HKLM\Software\EA Games\STAR WARS Battlefront II' /v 'Locale' /d 'en_US' /f "/reg:$view" >/dev/null 2>&1 \
    || warn "could not register the game install in the Wine registry (view $view)"
done
log "Registered game install: $WIN_GAME_DIR"

args=(./kyber_cli start_server --show-console
      --credentials="$EA_USER:$EA_PASS"
      --token "$TOKEN"
      --game-path "$GAME_EXE")
# --verbose echoes every argument; the console filter above hides the EA login and tokens.
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
  : > "$WATCH_DIR/stopping"   # tells the crash watchdog this is not a crash
  log "Stopping KYBER server ..."
  kill -INT "$kpid" 2>/dev/null
  for _ in $(seq 1 10); do kill -0 "$kpid" 2>/dev/null || return; sleep 1; done
  # kyber_cli waits for the game; end the game (every Wine process in this prefix).
  log "Closing the game ..."
  "$WINESERVER" -k >/dev/null 2>&1
  for _ in $(seq 1 15); do kill -0 "$kpid" 2>/dev/null || return; sleep 1; done
  kill -TERM "$kpid" 2>/dev/null; sleep 3; kill -KILL "$kpid" 2>/dev/null
  "$WINESERVER" -k9 >/dev/null 2>&1
}
trap stop_server INT TERM HUP

# ---------- crash watchdog ----------
# kyber_cli only exits when the game's EA (LSX) connection closes, so a crashed
# or frozen game can leave it running and AMP showing "Running" with no server.
# Turn every crash into a clear console message and a failed exit so AMP
# restarts the server:
#  - KYBER's crash handler updated its Sentry last_crash marker;
#  - the game process is gone while kyber_cli is still running;
#  - no heartbeat from the built-in plugin for Freeze Timeout seconds.
FREEZE_TIMEOUT="$(trim "${AMP_KYBER_FREEZE_TIMEOUT:-180}")"
case "$FREEZE_TIMEOUT" in ''|*[!0-9]*) FREEZE_TIMEOUT=180 ;; esac
[ -n "${KYBER_DEV_PLUGIN_PATH:-}" ] || FREEZE_TIMEOUT=0   # no plugin, no heartbeat
crash_marker() { stat -c %Y "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/ArmchairDevelopers/Kyber/ModuleData/Sentry/last_crash 2>/dev/null | sort -n | tail -n1; }
watchdog() {
  local marker seen=0 gone=0 reason age last_status beat
  marker="$(crash_marker)"
  last_status="$(date +%s)"
  while kill -0 "$kpid" 2>/dev/null; do
    sleep 5
    # One timestamped status line every 30 minutes instead of every heartbeat.
    if [ $(( $(date +%s) - last_status )) -ge 1800 ] && [ ! -f "$WATCH_DIR/stopping" ]; then
      last_status="$(date +%s)"
      if [ -f "$HEARTBEAT" ]; then
        beat=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT" 2>/dev/null || date +%s) ))
        log "$(date '+%Y-%m-%d %H:%M:%S %Z') Watchdog: server healthy (last server tick ${beat}s ago)."
      elif game_running; then
        log "$(date '+%Y-%m-%d %H:%M:%S %Z') Watchdog: game running (no server tick seen yet)."
      fi
    fi
    [ -f "$WATCH_DIR/stopping" ] && return
    reason=""
    if [ "$(crash_marker)" != "$marker" ]; then
      reason="the game crashed (KYBER's crash handler fired)"
    elif game_running; then
      seen=1; gone=0
    elif [ "$seen" = 1 ]; then
      gone=$((gone + 5)); [ "$gone" -ge 20 ] && reason="the game process ended but kyber_cli kept running"
    fi
    if [ -z "$reason" ] && [ "$FREEZE_TIMEOUT" -gt 0 ] && [ -f "$HEARTBEAT" ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT" 2>/dev/null || date +%s) ))
      [ "$age" -ge "$FREEZE_TIMEOUT" ] && reason="the game stopped responding (no server tick for ${age}s)"
    fi
    [ -f "$WATCH_DIR/stopping" ] && return
    if [ -n "$reason" ]; then
      printf '%s\n' "$reason" > "$WATCH_DIR/crashed"
      warn "CRASH DETECTED: $reason. Stopping the server so AMP restarts it."
      kill -INT "$kpid" 2>/dev/null
      for _ in $(seq 1 10); do kill -0 "$kpid" 2>/dev/null || break; sleep 1; done
      close_game >/dev/null 2>&1
      kill -TERM "$kpid" 2>/dev/null
      return
    fi
  done
}
if is_true "${AMP_KYBER_CRASH_WATCHDOG:-true}"; then
  watchdog &
  WATCHDOG_PID=$!
  [ "$FREEZE_TIMEOUT" -gt 0 ] && log "Crash watchdog on (freeze timeout ${FREEZE_TIMEOUT}s)." \
    || log "Crash watchdog on (freeze detection off: needs Show Players in AMP and a Freeze Timeout above 0)."
fi

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
[ -n "${WATCHDOG_PID:-}" ] && { kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null; }
if game_running; then
  log "Closing the game ..."
  close_game || warn "the game did not close. Use Stop, wait for Stopped, then Start."
fi
# A game crash that ends kyber_cli on its own is also a crash. AMP's Stop and
# Restart signal kyber_cli directly (exit 130/143/137), which is not.
case "$rc" in 130|143|137) stopped_by_signal=1 ;; *) stopped_by_signal=0 ;; esac
if [ ! -f "$WATCH_DIR/crashed" ] && [ ! -f "$WATCH_DIR/stopping" ] && [ "$stopping" = 0 ] && [ "$stopped_by_signal" = 0 ]; then
  printf 'the game exited without a stop request (exit code %s)\n' "$rc" > "$WATCH_DIR/crashed"
  warn "CRASH DETECTED: the server ended without a stop request (exit code $rc)."
fi
if [ -f "$WATCH_DIR/crashed" ]; then
  warn "Server crashed: $(cat "$WATCH_DIR/crashed"). KYBER's log is in the Wine prefix under AppData/Roaming/ArmchairDevelopers/Kyber/Logs."
  rc=1
fi
exec >&- 2>&-; wait "$CENSOR_PID" 2>/dev/null   # let the console filter print its last lines
exit "$rc"
