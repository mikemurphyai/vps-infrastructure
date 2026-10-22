#!/usr/bin/env bash
set -euo pipefail

# Weekly check: is there a Directus release newer than the one in our compose
# file that ships a Node.js with the October 2026 security fixes? Reports to
# the "Update: directus" Kuma push monitor:
#   up   = nothing to do yet (still waiting on a patched release)
#   down = a patched release is out -> Telegram alert, time to upgrade
# If this script stops running, the monitor's 8-day heartbeat lapses and Kuma
# alerts on that too. Nothing is pulled or changed on the server.

# ==== Settings ====
REPO="directus/directus"
COMPOSE="/docker/directus/docker-compose.yml"
LOG="/var/log/directus-update-check.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUMA_PUSH_URL="$(grep -m1 '^KUMA_UPDATE_PUSH_URL=' "${SCRIPT_DIR}/.env" | cut -d= -f2-)"    # from gitignored .env, not committed

# Minimum patched Node version per release line (Node security release
# 2026-10-21). Lines not listed here are treated as unpatched.
declare -A MIN_NODE=( [22]=22.23.4 [24]=24.22.1 [26]=26.12.1 )

# ==== Logging ====
log() { echo "[$(date -u +"%F %T") UTC] $*" | tee -a "$LOG" ; }

push() {  # push <up|down> <message>
  curl -fsS -m 10 --get "$KUMA_PUSH_URL" \
    --data-urlencode "status=$1" --data-urlencode "msg=$2" --data-urlencode "ping=" >/dev/null \
    || log "Warning: failed to ping Uptime Kuma push monitor."
}

# Version a >= version b
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

# ==== Current version (from the compose file the server actually runs) ====
CURRENT="$(grep -oE "image: *${REPO}:[0-9.]+" "$COMPOSE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$')"

# ==== Latest stable release on Docker Hub ====
LATEST="$(curl -fsS -m 30 "https://hub.docker.com/v2/repositories/${REPO}/tags?page_size=100" \
  | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

# ==== Node version baked into that release (registry metadata, no pull) ====
TOKEN="$(curl -fsS -m 30 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" | jq -r .token)"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
reg() { curl -fsSL -m 30 -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${ACCEPT}" "https://registry-1.docker.io/v2/${REPO}/$1"; }

MANIFEST="$(reg "manifests/${LATEST}")"
if echo "$MANIFEST" | jq -e '.manifests' >/dev/null; then
  DIGEST="$(echo "$MANIFEST" | jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' | head -1)"
  MANIFEST="$(reg "manifests/${DIGEST}")"
fi
CONFIG_DIGEST="$(echo "$MANIFEST" | jq -r .config.digest)"
NODE="$(reg "blobs/${CONFIG_DIGEST}" | jq -r '.config.Env[]' | grep -m1 '^NODE_VERSION=' | cut -d= -f2)"

if [ -z "$CURRENT" ] || [ -z "$LATEST" ] || [ -z "$NODE" ]; then
  log "Could not determine versions (current='$CURRENT' latest='$LATEST' node='$NODE'); not pinging Kuma."
  exit 1
fi

# ==== Decide ====
MIN="${MIN_NODE[${NODE%%.*}]:-}"
if [ -n "$MIN" ] && version_ge "$NODE" "$MIN"; then PATCHED=yes; else PATCHED=no; fi

if [ "$LATEST" != "$CURRENT" ] && version_ge "$LATEST" "$CURRENT" && [ "$PATCHED" = yes ]; then
  log "UPGRADE READY: running ${CURRENT}, ${LATEST} ships Node ${NODE} (patched)."
  push down "Directus ${LATEST} is out with patched Node ${NODE} (running ${CURRENT}) - time to upgrade"
else
  log "Waiting: running ${CURRENT}, latest ${LATEST} ships Node ${NODE} (patched: ${PATCHED})."
  push up "Running ${CURRENT}; latest ${LATEST} has Node ${NODE} (patched: ${PATCHED})"
fi
