#!/usr/bin/env bash
set -euo pipefail

# ==== Settings ====
VOLUME_NAME="shlink_shlink_data"
BACKUP_DIR="/var/backups/shlink"
LOG="/var/backups/shlink/backup.log"
TIMESTAMP="$(date -u +"%Y%m%d_%H%M%S")"
ARCHIVE="shlink_data_${TIMESTAMP}.tar.gz"
RETENTION_LOCAL_DAYS=14
RETENTION_REMOTE_DAYS=30               # used only if rclone is installed
LOCKFILE="/var/backups/shlink/.backup.lock"
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

# Create archive directly from the Docker volume
docker run --rm \
  -v "${VOLUME_NAME}:/data:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine:3.20 sh -c "tar czf /backup/${ARCHIVE} -C /data ."

# Integrity note (not required, but useful)
sha256sum "${BACKUP_DIR}/${ARCHIVE}" >> "${BACKUP_DIR}/sha256sums.txt" || true
log "Archive created: ${BACKUP_DIR}/${ARCHIVE}"

# Prune old local archives
find "$BACKUP_DIR" -type f -name "shlink_data_*.tar.gz" -mtime +"${RETENTION_LOCAL_DAYS}" -print -delete | tee -a "$LOG" || true
log "Local retention applied: > ${RETENTION_LOCAL_DAYS} days deleted (if any)."

# Offsite (only if rclone is installed & remote configured)
if command -v rclone >/dev/null 2>&1; then
  rclone copy "$BACKUP_DIR" "vault-nas:/Vault/Backups/Hostinger VPS/shlink" \
    --transfers=2 --checkers=4 \
    --create-empty-src-dirs \
    --log-file=/root/rclone_backup.log || true

  rclone delete "vault-nas:/Vault/Backups/Hostinger VPS/shlink" \
    --min-age "${RETENTION_REMOTE_DAYS}d" \
    --log-file=/root/rclone_backup.log || true

  log "Offsite sync complete (remote retention applied)."
else
  log "rclone not installed; skipping offsite sync."
fi

log "Backup completed successfully."

# Ping Uptime Kuma (dead-man's-switch monitor for this cron job)
curl -fsS -m 10 "$KUMA_PUSH_URL" >/dev/null 2>&1 || log "Warning: failed to ping Uptime Kuma push monitor."
