#!/usr/bin/env bash
set -euo pipefail

# ==== Settings ====
VOLUME_NAME="uptime-kuma_data"
BACKUP_DIR="/var/backups/uptime-kuma"
LOG="/var/backups/uptime-kuma/backup.log"
TIMESTAMP="$(date -u +"%Y%m%d_%H%M%S")"
ARCHIVE="uptime-kuma_data_${TIMESTAMP}.tar.gz"
RETENTION_LOCAL_DAYS=14
RETENTION_REMOTE_DAYS=30               # used only if rclone is installed
LOCKFILE="/var/backups/uptime-kuma/.backup.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUMA_PUSH_URL="$(grep -m1 '^KUMA_PUSH_URL=' "${SCRIPT_DIR}/.env" | cut -d= -f2-)"    # from gitignored .env, not committed

# ==== Logging ====
log() { echo "[$(date -u +"%F %T") UTC] $*" | tee -a "$LOG" ; }

# ==== Ensure backup dir exists ====
mkdir -p "$BACKUP_DIR"

# ==== Prevent overlapping runs ====
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "Another backup is already running; exiting."
  exit 0
fi

log "Starting backup for volume: $VOLUME_NAME"

# Optional image pull (harmless if offline)
docker pull alpine:3.20 >/dev/null 2>&1 || true

# Kuma writes to kuma.db constantly (WAL mode), so a raw tar of the volume can
# capture it mid-write. Use SQLite's online .backup for a consistent snapshot,
# then archive it with the small upload/screenshots/docker-tls dirs. The
# volume is mounted read-write only because WAL readers need the -shm file;
# nothing in it is modified. Legacy kuma.db.bak.* files are skipped.
docker run --rm \
  -v "${VOLUME_NAME}:/data" \
  -v "${BACKUP_DIR}:/backup" \
  alpine:3.20 sh -c "
    set -e
    apk add -q --no-cache sqlite >/dev/null
    mkdir -p /tmp/snap
    sqlite3 /data/kuma.db \".backup /tmp/snap/kuma.db\"
    [ \"\$(sqlite3 /tmp/snap/kuma.db 'PRAGMA integrity_check;')\" = ok ]
    for d in upload screenshots docker-tls; do [ -d /data/\$d ] && cp -a /data/\$d /tmp/snap/; done
    tar czf /backup/${ARCHIVE} -C /tmp/snap .
  "

# Integrity note (not required, but useful)
sha256sum "${BACKUP_DIR}/${ARCHIVE}" >> "${BACKUP_DIR}/sha256sums.txt" || true
log "Archive created: ${BACKUP_DIR}/${ARCHIVE}"

# Prune old local archives
find "$BACKUP_DIR" -maxdepth 1 -type f -name "uptime-kuma_data_*.tar.gz" -mtime +"${RETENTION_LOCAL_DAYS}" -print -delete | tee -a "$LOG" || true
log "Local retention applied: > ${RETENTION_LOCAL_DAYS} days deleted (if any)."

# Offsite (only if rclone is installed & remote configured)
OFFSITE_OK=1
if command -v rclone >/dev/null 2>&1; then
  rclone copy "$BACKUP_DIR" "vault-nas:/Vault/Backups/Hostinger VPS/uptime-kuma" \
    --transfers=2 --checkers=4 \
    --create-empty-src-dirs \
    --log-file=/root/rclone_backup.log || OFFSITE_OK=0

  rclone delete "vault-nas:/Vault/Backups/Hostinger VPS/uptime-kuma" \
    --min-age "${RETENTION_REMOTE_DAYS}d" \
    --log-file=/root/rclone_backup.log || true

  if [ "$OFFSITE_OK" = 1 ]; then
    log "Offsite sync complete (remote retention applied)."
  else
    log "Offsite sync to NAS FAILED (see /root/rclone_backup.log)."
  fi
else
  log "rclone not installed; skipping offsite sync."
fi

log "Backup completed successfully."

# Ping Uptime Kuma (dead-man's-switch monitor for this cron job)
# A failed NAS sync reports "down" (Telegram alert) instead of "up", so an
# unreachable NAS can't go unnoticed while local backups keep succeeding.
if [ "$OFFSITE_OK" = 1 ]; then
  curl -fsS -m 10 "$KUMA_PUSH_URL" >/dev/null 2>&1 || log "Warning: failed to ping Uptime Kuma push monitor."
else
  curl -fsS -m 10 --get "${KUMA_PUSH_URL%%\?*}" \
    --data-urlencode "status=down" \
    --data-urlencode "msg=Local backup OK, but offsite sync to the NAS failed (see /root/rclone_backup.log)" \
    >/dev/null 2>&1 || log "Warning: failed to ping Uptime Kuma push monitor."
fi
