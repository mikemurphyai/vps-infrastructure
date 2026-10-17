#!/bin/bash
# VPS maintenance: OS updates + rolling update of every docker-compose stack
# under /docker/. Safe to run interactively (bash /docker/maintain.sh) or
# fully detached (see the n8n workflow, which dispatches this in the
# background so its own restart mid-run can't kill the process).
export DEBIAN_FRONTEND=noninteractive

LOG_DIR="/var/log/vps-maintenance"
LOG_FILE="$LOG_DIR/last-run.log"
mkdir -p "$LOG_DIR"

# Mirror everything to both the terminal (if any) and the log file, so a
# webhook-dispatched run and an interactive run produce the same report.
exec > >(tee "$LOG_FILE") 2>&1

FAILED=0
ok()      { echo "✅ $1"; }
fail()    { echo "❌ $1"; FAILED=1; }
section() { echo; echo "=== $1 ==="; }

echo "VPS Maintenance started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

section "1. Updating Ubuntu OS"
if apt-get update && apt-get upgrade -y && apt-get autoremove -y; then
    ok "OS packages updated"
else
    fail "OS package update failed"
fi

section "2. Updating Docker Services"
for compose in /docker/*/docker-compose.yml; do
    [ -f "$compose" ] || continue
    dir=$(dirname "$compose")
    svc=$(basename "$dir")
    # Deployment backups are recovery copies, never runnable stacks.
    case "$svc" in
        *.backup|*.backup-*|*.bak|*.bak-*)
            echo "--- Skipping backup directory: $svc ---"
            continue
            ;;
    esac
    if [ -f "$dir/.maintenance-ignore" ]; then
        echo "--- Skipping excluded directory: $svc ---"
        continue
    fi
    echo "--- $svc ---"
    if (cd "$dir" && docker compose pull && docker compose up -d); then
        ok "$svc updated"
    else
        fail "$svc update failed — check manually: cd $dir && docker compose logs"
    fi
done

section "3. Cleaning up old Docker images"
if docker image prune -f >/dev/null; then
    ok "Old images pruned"
else
    fail "Image prune failed"
fi

section "Summary"
echo "VPS Maintenance finished: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if [ "$FAILED" -eq 1 ]; then
    echo "RESULT: FAILED — one or more steps above need attention."
    exit 1
else
    echo "RESULT: SUCCESS — everything updated, you're good to go."
    exit 0
fi
