#!/bin/bash
# KYBER for AMP3 - install / update stage.
#
# AMP3 runs every shard in its own rootless container, so the official
# KYBER docker image cannot be started from inside a shard. Instead this
# script pulls the KYBER runtime files (kyber_cli, maxima, KYBER module)
# straight out of the published KYBER image layers, installs the same
# GE-Proton Wine build the image uses, and optionally downloads the game.
#
# Usage: kyber-install.sh <FullBaseDir>
# Env:   KYBER_IMAGE, KYBER_WINE_URL, KYBER_GAME_DIR, KYBER_EA_TOKEN, KYBER_VERIFY_GAME, KYBER_FORCE_RUNTIME

set -uo pipefail
BASE="${1:?base dir missing}"; BASE="${BASE%/}"
log()  { echo "[KYBER] $*"; }
fail() { echo "[KYBER] ERROR: $*"; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
# AMP checkboxes arrive as "True", "setting.X.value.True" or similar, not "true".
is_true() { case "$(trim "${1:-}" | tr '[:upper:]' '[:lower:]')" in true|1|yes|on|enabled|*.true) return 0 ;; *) return 1 ;; esac; }

IMAGE="$(trim "${KYBER_IMAGE:-}")";        [ -z "$IMAGE" ] && IMAGE="ghcr.io/armchairdevelopers/kyber-server:latest"
WINE_URL="$(trim "${KYBER_WINE_URL:-}")";  [ -z "$WINE_URL" ] && WINE_URL="https://github.com/GloriousEggroll/wine-ge-custom/releases/download/GE-Proton8-26/wine-lutris-GE-Proton8-26-x86_64.tar.xz"
GAME_DIR="$(trim "${KYBER_GAME_DIR:-}")";  [ -z "$GAME_DIR" ] && GAME_DIR="$BASE/battlefront"
EA_TOKEN="$(trim "${KYBER_EA_TOKEN:-}")"

RUNTIME="$BASE/runtime"
WINE_DIR="$BASE/wine"
MODULE_DIR="$HOME/.local/share/kyber/module"
TMP="$BASE/.kyber-tmp"
mkdir -p "$BASE" "$RUNTIME" "$BASE/mods" "$BASE/plugins" "$MODULE_DIR" "$GAME_DIR" || fail "cannot create folders under $BASE"
rm -rf "$TMP"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

for tool in curl jq tar; do command -v "$tool" >/dev/null || fail "$tool is missing from the container image"; done

# ---------------------------------------------------------------- KYBER runtime
# IMAGE = [registry/]repo[:tag]
ref="$IMAGE"; tag="latest"
if [[ "${ref##*/}" == *:* ]]; then tag="${ref##*:}"; ref="${ref%:*}"; fi
registry="${ref%%/*}"; repo="${ref#*/}"
[[ "$registry" == *.* || "$registry" == *:* ]] || { registry="registry-1.docker.io"; repo="$ref"; }
[ "$registry" = "docker.io" ] && registry="registry-1.docker.io"
API="https://$registry/v2/$repo"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

auth=()
# The registry root answers GET /v2/ with a 401 whose header says where to get a token.
challenge="$(curl -s -o /dev/null -D - "https://$registry/v2/" | tr -d '\r' | grep -i '^www-authenticate:' || true)"
if [[ "$challenge" == *Bearer* ]]; then
  realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")"
  service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")"
  token="$(curl -fsSL "$realm?service=$service&scope=repository:$repo:pull" | jq -r '.token // .access_token')" || fail "could not get a registry token for $IMAGE"
  auth=(-H "Authorization: Bearer $token")
fi

log "Resolving $IMAGE ..."
manifest="$(curl -fsSL "${auth[@]}" -H "Accept: $ACCEPT" "$API/manifests/$tag")" || fail "could not read the manifest of $IMAGE"
if jq -e '.manifests' >/dev/null <<<"$manifest"; then
  digest="$(jq -r '[.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64")][0].digest' <<<"$manifest")"
  [ -n "$digest" ] && [ "$digest" != null ] || fail "$IMAGE has no linux/amd64 build"
  manifest="$(curl -fsSL "${auth[@]}" -H "Accept: $ACCEPT" "$API/manifests/$digest")" || fail "could not read the amd64 manifest"
fi
config_digest="$(jq -r '.config.digest' <<<"$manifest")"

if [ "${KYBER_FORCE_RUNTIME:-false}" != "true" ] && [ -f "$RUNTIME/.image-config" ] \
   && [ "$(cat "$RUNTIME/.image-config")" = "$config_digest" ] && [ -x "$RUNTIME/opt/kyber/kyber_cli" ]; then
  log "KYBER runtime is up to date (${config_digest:7:12})."
else
  config="$(curl -fsSL "${auth[@]}" "$API/blobs/$config_digest")" || fail "could not read the image config"
  # Layers created by COPY hold the KYBER files; the others are distro packages we already have.
  mapfile -t wanted < <(jq -r --argjson m "$manifest" '
      [.history[] | select(.empty_layer != true)] as $h
      | range(0; $h|length) | select(($h[.].created_by // "") | test("COPY")) | $m.layers[.].digest' <<<"$config")
  [ "${#wanted[@]}" -gt 0 ] || fail "found no KYBER files in $IMAGE"
  rm -rf "$RUNTIME.new"; mkdir -p "$RUNTIME.new"
  for d in "${wanted[@]}"; do
    log "Fetching layer ${d:7:12} ..."
    curl -fsSL "${auth[@]}" "$API/blobs/$d" -o "$TMP/layer" || fail "download of layer $d failed"
    tar -xzf "$TMP/layer" -C "$RUNTIME.new" --no-same-owner --no-same-permissions \
        --wildcards 'opt/kyber/*' 'root/.local/share/kyber/*' 2>/dev/null || true
  done
  [ -f "$RUNTIME.new/opt/kyber/kyber_cli" ] || fail "kyber_cli was not found in $IMAGE"
  chmod +x "$RUNTIME.new/opt/kyber/kyber_cli" "$RUNTIME.new/opt/kyber/maxima-bootstrap" 2>/dev/null
  echo "$config_digest" > "$RUNTIME.new/.image-config"
  rm -rf "$RUNTIME"; mv "$RUNTIME.new" "$RUNTIME"
  log "KYBER runtime installed (${config_digest:7:12})."
fi

# KYBER module files belong in ~/.local/share/kyber/module (the image keeps them under /root).
if [ -d "$RUNTIME/root/.local/share/kyber/module" ]; then
  cp -f "$RUNTIME/root/.local/share/kyber/module/"* "$MODULE_DIR/" || fail "could not install the KYBER module files"
  log "KYBER module files installed to $MODULE_DIR"
fi

# ---------------------------------------------------------------- Wine (GE-Proton build used by KYBER)
if [ -x "$WINE_DIR/bin/wine64" ] && [ "$(cat "$WINE_DIR/.source" 2>/dev/null)" = "$WINE_URL" ]; then
  log "Wine is up to date."
else
  log "Downloading Wine: $WINE_URL"
  curl -fL --retry 3 -o "$TMP/wine.tar.xz" "$WINE_URL" || fail "Wine download failed"
  rm -rf "$WINE_DIR.new"; mkdir -p "$WINE_DIR.new"
  tar -xJf "$TMP/wine.tar.xz" -C "$WINE_DIR.new" --strip-components=1 || fail "could not unpack Wine"
  echo "$WINE_URL" > "$WINE_DIR.new/.source"
  rm -rf "$WINE_DIR"; mv "$WINE_DIR.new" "$WINE_DIR"
  rm -rf "$HOME/.local/share/maxima/wine/prefix"   # rebuild the prefix for the new Wine
  log "Wine installed."
fi

# ---------------------------------------------------------------- Game files
# Once the game is installed, Update leaves it alone (no EA login, so an expired
# EA token does not break updates). Set KYBER_VERIFY_GAME to re-check the files.
GAME_EXE="$(find "$GAME_DIR" -maxdepth 1 -iname 'starwarsbattlefrontii.exe' 2>/dev/null | head -n1)"
if [ -n "$GAME_EXE" ] && ! is_true "${KYBER_VERIFY_GAME:-}"; then
  log "Game files found in $GAME_DIR; skipping the game download (enable 'Verify Game Files on Update' to re-check them)."
elif [ -n "$EA_TOKEN" ]; then
  log "Downloading / verifying Star Wars Battlefront II into $GAME_DIR (about 90 GB on first install) ..."
  # kyber_cli download_game does not exit on its own once it reaches 100%, and it
  # redraws a progress spinner every 0.2s. Run it in the background, show every
  # 5% step, and close it ourselves shortly after it reports 100%.
  DL_LOG="$TMP/download.log"; : > "$DL_LOG"
  # After downloading, kyber_cli runs a "touchup" that verifies Wine dependencies,
  # so give it the same Wine setup the server uses.
  mkdir -p "$HOME/.local/share/maxima/wine/prefix"
  ( cd "$RUNTIME/opt/kyber" && export KYBER_BYPASS_DOCKER_I_REALLY_KNOW_WHAT_I_AM_DOING=1 \
      MAXIMA_DISABLE_WINE_VERIFICATION=1 MAXIMA_DISABLE_QRC=1 \
      MAXIMA_WINE_COMMAND="$WINE_DIR/bin/wine64" WINEPREFIX="$HOME/.local/share/maxima/wine/prefix" \
      WINEDEBUG=-all LD_LIBRARY_PATH="$RUNTIME/opt/kyber" && \
      exec ./kyber_cli download_game -p "$GAME_DIR" -t "$EA_TOKEN" ) >"$DL_LOG" 2>&1 &
  dl_pid=$!
  # If AMP aborts the update, take kyber_cli down with us instead of orphaning it.
  stop_download() { kill "$dl_pid" 2>/dev/null; sleep 2; kill -9 "$dl_pid" 2>/dev/null; }
  trap 'stop_download; rm -rf "$TMP"; echo "[KYBER] Update aborted."; exit 130' TERM INT HUP
  tail -n +1 -f --pid="$dl_pid" "$DL_LOG" | tr '\r' '\n' | awk '
      match($0, /\(([0-9]+)(\.[0-9]+)?%\)/) {
        p = int(substr($0, RSTART + 1, RLENGTH - 3) / 5) * 5
        if (p != last) { last = p; print "[KYBER] Downloading game... " p "%"; fflush() }
        next
      }
      NF { print; fflush() }' &
  show_pid=$!
  # Once 100% is reached, wait until kyber_cli has printed nothing but spinner
  # redraws for 60s (its touchup steps print real lines), then close it.
  done_at=0; quiet_since=0; last_real=""
  while kill -0 "$dl_pid" 2>/dev/null; do
    sleep 2
    if [ "$done_at" = 0 ] && tr '\r' '\n' < "$DL_LOG" | grep -aqE '\(100(\.0+)?%\)'; then
      done_at=$SECONDS; quiet_since=$SECONDS
      log "Download reached 100%. Waiting for kyber_cli to finish its checks ..."
    fi
    [ "$done_at" = 0 ] && continue
    real="$(tr '\r' '\n' < "$DL_LOG" | grep -av '%)' | grep -a . | tail -n 1)"
    if [ "$real" != "$last_real" ]; then last_real="$real"; quiet_since=$SECONDS; fi
    if [ $((SECONDS - quiet_since)) -ge 60 ]; then
      log "kyber_cli has finished but stayed open; closing it."
      stop_download
      break
    fi
  done
  wait "$dl_pid" 2>/dev/null; dl_rc=$?
  wait "$show_pid" 2>/dev/null
  trap - TERM INT HUP
  [ "$done_at" != 0 ] && dl_rc=0
  if [ "$dl_rc" -eq 0 ]; then
    log "Game download finished."
  elif [ -n "$GAME_EXE" ]; then
    log "WARNING: game verification failed (the EA token has probably expired). The existing game files are kept; create a fresh token with 'kyber_cli get_ea_token' to verify again."
  else
    fail "game download failed. EA tokens expire quickly - create a fresh one with 'kyber_cli get_ea_token' and update again."
  fi
else
  log "WARNING: no game files in $GAME_DIR. Set 'EA Token (game download)' and update again, or upload the game files there."
fi

log "Install/update complete."
