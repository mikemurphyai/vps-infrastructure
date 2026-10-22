#!/usr/bin/env bash
set -euo pipefail

# Is there a release of an app image, newer than the one in its compose file,
# that ships a Node.js with the October 2026 security fixes? Reports to the
# app's "Update: <name>" Kuma push monitor:
#   up   = nothing to do yet (still waiting on a patched release)
#   down = a patched release is out -> Telegram alert, time to upgrade
# If this stops running, the monitor's heartbeat lapses and Kuma alerts on
# that too. Nothing is pulled or changed on the server.
#
# Installed on the VPS as /usr/local/sbin/check_image_update.sh, run from cron:
#   check_image_update.sh <name> <hub repo> <release tag> <compose file> <env file>
# <release tag> is the project's floating tag for stable releases (n8n uses
# "stable"; "latest" elsewhere) — it's resolved to the X.Y.Z tag with the same
# digest, so betas published as plain X.Y.Z tags are never picked up.
# <env file> must contain KUMA_UPDATE_PUSH_URL (gitignored, not committed).

# ==== Settings ====
NAME="$1"
REPO="$2"
RELEASE_TAG="$3"
COMPOSE="$4"
ENV_FILE="$5"
LOG="/var/log/${NAME}-update-check.log"
KUMA_PUSH_URL="$(grep -m1 '^KUMA_UPDATE_PUSH_URL=' "$ENV_FILE" | cut -d= -f2-)"

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
# Matches "image: repo:1.2.3" with optional quotes and registry host
# (e.g. docker.n8n.io/n8nio/n8n).
CURRENT="$(grep -oE "image: *\"?([a-z0-9.-]+/)?${REPO}:[0-9]+\.[0-9]+\.[0-9]+" "$COMPOSE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"

# ==== Latest stable release on Docker Hub ====
LATEST="$(curl -fsS -m 30 "https://hub.docker.com/v2/repositories/${REPO}/tags?page_size=100" \
  | jq -r --arg t "$RELEASE_TAG" '
      (.results[] | select(.name==$t) | .digest) as $d
      | [.results[] | select(.digest==$d and (.name|test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) | .name]
      | .[]' | sort -V | tail -1)"

# ==== Node version baked into that release (registry metadata, no pull) ====
TOKEN="$(curl -fsS -m 30 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" | jq -r .token)"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
reg() { curl -fsSL -m 30 -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${ACCEPT}" "https://registry-1.docker.io/v2/${REPO}/$1"; }

NODE=""
if [ -n "$LATEST" ]; then
  MANIFEST="$(reg "manifests/${LATEST}")"
  if echo "$MANIFEST" | jq -e '.manifests' >/dev/null; then
    DIGEST="$(echo "$MANIFEST" | jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' | head -1)"
    MANIFEST="$(reg "manifests/${DIGEST}")"
  fi
  CONFIG_DIGEST="$(echo "$MANIFEST" | jq -r .config.digest)"
  # Alpine-packaged Node reports e.g. "26.10.0-r0"; keep only X.Y.Z
  NODE="$(reg "blobs/${CONFIG_DIGEST}" | jq -r '.config.Env[]' | grep -m1 '^NODE_VERSION=' | cut -d= -f2 | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
fi

if [ -z "$CURRENT" ] || [ -z "$LATEST" ] || [ -z "$NODE" ]; then
  log "${NAME}: could not determine versions (current='$CURRENT' latest='$LATEST' node='$NODE'); not pinging Kuma."
  exit 1
fi

# ==== Decide ====
MIN="${MIN_NODE[${NODE%%.*}]:-}"
if [ -n "$MIN" ] && version_ge "$NODE" "$MIN"; then PATCHED=yes; else PATCHED=no; fi

if [ "$LATEST" != "$CURRENT" ] && version_ge "$LATEST" "$CURRENT" && [ "$PATCHED" = yes ]; then
  log "${NAME}: UPGRADE READY: running ${CURRENT}, ${LATEST} ships Node ${NODE} (patched)."
  push down "${NAME} ${LATEST} is out with patched Node ${NODE} (running ${CURRENT}) - time to upgrade"
else
  log "${NAME}: waiting: running ${CURRENT}, latest ${LATEST} ships Node ${NODE} (patched: ${PATCHED})."
  push up "Running ${CURRENT}; latest ${LATEST} has Node ${NODE} (patched: ${PATCHED})"
fi
