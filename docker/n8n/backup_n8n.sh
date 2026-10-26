#!/usr/bin/env bash
set -euo pipefail

# ==== Settings ====
VOLUME_NAME="n8n_data"                 # <-- change if your volume is different
BACKUP_DIR="/var/backups/n8n"
LOG="/var/backups/n8n/backup.log"
TIMESTAMP="$(date -u +"%Y%m%d_%H%M%S")"
ARCHIVE="n8n_data_${TIMESTAMP}.tar.gz"
RETENTION_LOCAL_DAYS=14
RETENTION_REMOTE_DAYS=30               # used only if rclone is installed
LOCKFILE="/var/backups/n8n/.backup.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUMA_PUSH_URL="$(grep -m1 '^KUMA_PUSH_URL=' "${SCRIPT_DIR}/.env" | cut -d= -f2-)"    # from gitignored .env, not committed

# ==== Logging ====
log() { echo "[$(date -u +"%F %T") UTC] $*" | tee -a "$LOG" ; }

# ==== Prevent overlapping runs ====
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "Another backup is already running; exiting."
  exit 0
fi

# ==== Ensure backup dir exists ====
mkdir -p "$BACKUP_DIR"

log "Starting backup for volume: $VOLUME_NAME"

# Optional image pull (harmless if offline)
docker pull alpine:3.20 >/dev/null 2>&1 || true

# Create archive directly from the Docker volume
docker run --rm \
  -v "${VOLUME_NAME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine:3.20 sh -c "tar czf /backup/${ARCHIVE} -C /data ."

# Integrity note (not required, but useful)
sha256sum "${BACKUP_DIR}/${ARCHIVE}" >> "${BACKUP_DIR}/sha256sums.txt" || true
log "Archive created: ${BACKUP_DIR}/${ARCHIVE}"

# Prune old local archives
find "$BACKUP_DIR" -type f -name "n8n_data_*.tar.gz" -mtime +"${RETENTION_LOCAL_DAYS}" -print -delete | tee -a "$LOG" || true
log "Local retention applied: > ${RETENTION_LOCAL_DAYS} days deleted (if any)."

# Offsite (only if rclone is installed & remote configured)
OFFSITE_OK=1
if command -v rclone >/dev/null 2>&1; then
  rclone copy "$BACKUP_DIR" "vault-nas:/Vault/Backups/Hostinger VPS/n8n" \
    --transfers=2 --checkers=4 \
    --create-empty-src-dirs \
    --log-file=/root/rclone_backup.log || OFFSITE_OK=0

  rclone delete "vault-nas:/Vault/Backups/Hostinger VPS/n8n" \
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
