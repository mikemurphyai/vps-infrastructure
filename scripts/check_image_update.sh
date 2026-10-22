#!/usr/bin/env bash
set -euo pipefail

# Is there an official release of an app image, newer than the one in its
# compose file, whose runtime (Node.js or PHP) has the October 2026 security
# fixes? Reports to the app's "Update: <name>" Kuma push monitor:
#   up   = nothing to do yet (still waiting on a patched release)
#   down = a patched release is out -> Telegram alert, time to upgrade
# If the compose file isn't on the official image (e.g. Shlink's local
# patched build), any patched official release counts as "time to switch".
# If this stops running, the monitor's heartbeat lapses and Kuma alerts on
# that too. Nothing is pulled or changed on the server.
#
# Installed on the VPS as /usr/local/sbin/check_image_update.sh, run from cron:
#   check_image_update.sh <name> <hub repo> <release tag> <compose file> <env file> [node|php]
# <release tag> is the project's floating tag for stable releases (n8n and
# Shlink use "stable"; "latest" elsewhere) — it's resolved to the X.Y.Z tag
# with the same digest, so betas published as plain X.Y.Z tags are ignored.
# <env file> must contain KUMA_UPDATE_PUSH_URL (gitignored, not committed).

# ==== Settings ====
NAME="$1"
REPO="$2"
RELEASE_TAG="$3"
COMPOSE="$4"
ENV_FILE="$5"
RUNTIME="${6:-node}"
LOG="/var/log/${NAME}-update-check.log"
KUMA_PUSH_URL="$(grep -m1 '^KUMA_UPDATE_PUSH_URL=' "$ENV_FILE" | cut -d= -f2-)"

# Minimum patched runtime version per release line (Node security release
# and PHP2Shell, both 2026-10-21). Lines not listed are treated as unpatched.
declare -A MIN_NODE=( [22]=22.23.4 [24]=24.22.1 [26]=26.12.1 )            # keyed by major
declare -A MIN_PHP=( [8.2]=8.2.35 [8.3]=8.3.36 [8.4]=8.4.27 [8.5]=8.5.12 ) # keyed by major.minor

case "$RUNTIME" in
  node) RT_LABEL="Node"; RT_ENV="NODE_VERSION" ;;
  php)  RT_LABEL="PHP";  RT_ENV="PHP_VERSION" ;;
  *)    echo "Unknown runtime: $RUNTIME (expected node or php)" >&2; exit 2 ;;
esac

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
# (e.g. docker.n8n.io/n8nio/n8n). Empty = not on the official image.
CURRENT="$(grep -oE "image: *\"?([a-z0-9.-]+/)?${REPO}:[0-9]+\.[0-9]+\.[0-9]+" "$COMPOSE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

# ==== Latest stable release on Docker Hub ====
LATEST="$(curl -fsS -m 30 "https://hub.docker.com/v2/repositories/${REPO}/tags?page_size=100" \
  | jq -r --arg t "$RELEASE_TAG" '
      (.results[] | select(.name==$t) | .digest) as $d
      | [.results[] | select(.digest==$d and (.name|test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) | .name]
      | .[]' | sort -V | tail -1)"

# ==== Runtime version baked into that release (registry metadata, no pull) ====
TOKEN="$(curl -fsS -m 30 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO}:pull" | jq -r .token)"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
reg() { curl -fsSL -m 30 -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${ACCEPT}" "https://registry-1.docker.io/v2/${REPO}/$1"; }

RT_VER=""
if [ -n "$LATEST" ]; then
  MANIFEST="$(reg "manifests/${LATEST}")"
  if echo "$MANIFEST" | jq -e '.manifests' >/dev/null; then
    DIGEST="$(echo "$MANIFEST" | jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' | head -1)"
    MANIFEST="$(reg "manifests/${DIGEST}")"
  fi
  CONFIG_DIGEST="$(echo "$MANIFEST" | jq -r .config.digest)"
  # Alpine-packaged Node reports e.g. "26.10.0-r0"; keep only X.Y.Z
  RT_VER="$(reg "blobs/${CONFIG_DIGEST}" | jq -r '.config.Env[]' | grep -m1 "^${RT_ENV}=" | cut -d= -f2 | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
fi

if [ -z "$LATEST" ] || [ -z "$RT_VER" ]; then
  log "${NAME}: could not determine versions (current='$CURRENT' latest='$LATEST' ${RT_LABEL}='$RT_VER'); not pinging Kuma."
  exit 1
fi

# ==== Decide ====
if [ "$RUNTIME" = php ]; then
  MIN="${MIN_PHP[$(echo "$RT_VER" | cut -d. -f1-2)]:-}"
else
  MIN="${MIN_NODE[${RT_VER%%.*}]:-}"
fi
if [ -n "$MIN" ] && version_ge "$RT_VER" "$MIN"; then PATCHED=yes; else PATCHED=no; fi

if [ -z "$CURRENT" ]; then
  RUNNING="a local build"
  NEWER=yes
else
  RUNNING="$CURRENT"
  if [ "$LATEST" != "$CURRENT" ] && version_ge "$LATEST" "$CURRENT"; then NEWER=yes; else NEWER=no; fi
fi

if [ "$NEWER" = yes ] && [ "$PATCHED" = yes ]; then
  log "${NAME}: UPGRADE READY: running ${RUNNING}, official ${LATEST} ships ${RT_LABEL} ${RT_VER} (patched)."
  push down "${NAME} ${LATEST} is out with patched ${RT_LABEL} ${RT_VER} (running ${RUNNING}) - time to upgrade"
else
  log "${NAME}: waiting: running ${RUNNING}, latest ${LATEST} ships ${RT_LABEL} ${RT_VER} (patched: ${PATCHED})."
  push up "Running ${RUNNING}; latest ${LATEST} has ${RT_LABEL} ${RT_VER} (patched: ${PATCHED})"
fi
