#!/usr/bin/env bash
set -euo pipefail
umask 077
BACKUP_DIR=/var/backups/stylelock
mkdir -p "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.backup.lock"
flock -n 9 || exit 0
cd /docker/stylelock
archive="stylelock_$(date -u +%Y%m%d_%H%M%S).sqlite3"
docker compose exec -T stylelock python scripts/backup-library.py --output "/tmp/$archive"
docker compose exec -T stylelock cat "/tmp/$archive" > "$BACKUP_DIR/$archive"
chmod 600 "$BACKUP_DIR/$archive"
docker compose exec -T stylelock rm "/tmp/$archive"
timeout 120 rclone copyto "$BACKUP_DIR/$archive" "vault-nas:/Vault/Backups/Hostinger VPS/stylelock/$archive" --retries 2 --contimeout 10s --timeout 30s
printf '%s Backup completed: %s (local and NAS)\n' "$(date -u +%FT%TZ)" "$archive"
# Retention is deliberately manual until the team chooses its policy.
