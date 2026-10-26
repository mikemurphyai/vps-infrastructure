# VPS Infrastructure

This repository is the **single source of truth** for the Infrastructure-as-Code
configuration running on Mike Murphy's Hostinger VPS (`hostinger-vps`,
`<VPS_PUBLIC_IP>`). Every service on the box is defined as a Docker Compose
stack under `docker/`. Public services are fronted by Traefik; private
services remain on the shared Docker network or a Tailscale-only binding.
The tracked configuration is kept in sync here so the live server state is
reproducible from version control.

If it runs on the VPS, its `docker-compose.yml` should live here. If it lives
here but isn't deployed yet, treat it as a documented-but-pending service.

---

## 1. Project Overview

- **Reverse proxy:** Traefik v2.11 (`docker/traefik/`) — owns ports 80/443,
  handles Let's Encrypt via TLS-ALPN-01 / DNS challenge (Cloudflare), and
  routes all public subdomains under `imurph.com`.
- **Shared network:** every service joins the external Docker network
  `app-net` so containers can resolve each other by container name.
- **n8n AI Assistant:** n8n uses an internal, self-hosted sandbox for code
  execution and an internal SearXNG instance for web search. Neither service
  publishes a host port; n8n reaches both by Docker DNS over `app-net`.
- **Public vs. internal:** public services get Traefik labels and a
  `*.imurph.com` subdomain; internal-only services (e.g. Ollama) are
  reachable only on `app-net` or bound to the host's Tailscale IP
  (`<TAILSCALE_IP>`), never exposed on `0.0.0.0`.
- **Cloudflare-only origin (2026-07-22):** ports 80/443 only accept
  connections from Cloudflare's published IP ranges — direct-to-IP scanning
  of the origin is dropped at the firewall. Enforced by
  `scripts/cf-lockdown.sh` via the `DOCKER-USER` iptables chain (Docker
  published ports bypass ufw, so ufw rules alone can't do this). Installed
  on the host as a systemd service (reapplies on boot) + weekly timer
  (refreshes Cloudflare's ranges). All `*.imurph.com` subdomains are
  Cloudflare-proxied, so legitimate traffic is unaffected — this only closes
  the side door.
- **Secrets:** each service directory has its own `.env` (gitignored) —
  never committed. Compose files, scripts, and non-secret configuration such
  as `searxng-settings.yml` are tracked.

---

## 2. Directory Structure

```
vps-infrastructure/
├── README.md
├── .gitignore
├── scripts/
│   ├── maintain.sh              # OS + container update pipeline (see §5)
│   ├── cf-lockdown.sh           # Cloudflare-only firewall for ports 80/443 (see §1)
│   └── check_image_update.sh    # Kuma alert when an app release ships patched Node/PHP (Directus, n8n, Shlink)
├── vps_maintenance_dasshboard    # n8n workflow export — webhook-triggered maintenance
└── docker/
    ├── traefik/
    │   └── docker-compose.yml    # reverse proxy / TLS termination
    ├── n8n/
    │   ├── docker-compose.yml
    │   └── backup_n8n.sh         # n8n_data volume backup (local + offsite via rclone → NAS, see §7)
    ├── n8n-sandbox/
    │   └── docker-compose.yml    # Internal n8n AI Assistant sandbox API + Docker-in-Docker runner
    ├── searxng/
    │   ├── docker-compose.yml    # Internal search backend for the n8n AI Assistant
    │   └── searxng-settings.yml  # Enables the JSON response format required by n8n
    ├── ollama/
    │   └── docker-compose.yml
    ├── open-webui/
    │   └── docker-compose.yml
    ├── cv-rag/
    │   └── docker-compose.yml    # Streamlit frontend, calls n8n via app-net
    ├── directus/
    │   ├── docker-compose.yml
    │   └── backup_directus.sh    # pg_dump + uploads tar (local + offsite via rclone → NAS)
    ├── excalidraw/
    │   └── docker-compose.yml    # Excalidraw whiteboard
    ├── shlink/
    │   ├── docker-compose.yml    # shlink + shlink-web-client
    │   └── backup_shlink.sh      # shlink_shlink_data volume backup (local + offsite via rclone → NAS)
    ├── podcast-rss/
    │   ├── docker-compose.yml    # Podcast Asset Finder web app
    │   ├── .env.example
    │   └── README.md             # Deployment and rollback runbook
    └── uptime_kuma/
        ├── docker-compose.yml    # live at uptime.imurph.com (see §7 Monitoring)
        └── backup_uptime_kuma.sh # kuma.db online .backup + data dirs (local + offsite via rclone → NAS)
```

---

## 3. Assigned Ports Ledger

Host-level port bindings as actually running on the VPS (`docker ps`), not
just what's declared in compose — some services are only reachable through
Traefik and never bind a host port directly.

| Service | Host Binding | Container Port | Exposure |
|---|---|---|---|
| Traefik | `0.0.0.0:80`, `0.0.0.0:443` | 80, 443 | Public HTTP(S) ingress — Cloudflare IPs only (see §1 origin lockdown) |
| Ollama | `<TAILSCALE_IP>:11434` | 11434 | Tailscale-only (locked down from `0.0.0.0`, see §7) |
| Open WebUI | `<TAILSCALE_IP>:8080` | 8080 | Tailscale-only (locked down from `0.0.0.0`, see §7) |
| Directus | — (Traefik only) | 8055 | Public via `cms.imurph.com` (2026-07-22, was Tailscale-only) |
| Excalidraw | — (Traefik only) | 80 | Public via `${SUBDOMAIN}.${DOMAIN_NAME}` |
| n8n | — (Traefik only) | 5678 | Public via `flow.imurph.com` |
| n8n Sandbox API | — (internal only) | 8080, 9090 | `app-net` only, no host binding |
| n8n Sandbox Runner | — (internal only) | 8080, 9091 | `app-net` only, privileged Docker-in-Docker |
| SearXNG | — (internal only) | 8080 | `app-net` only, no host binding |
| cv-rag Streamlit | — (Traefik only) | 8501 | Public via `chat.imurph.com` |
| Shlink | — (Traefik only) | 8080 | Public via `${SUBDOMAIN}.imurph.com` + short domain |
| Shlink Web Client | — (Traefik only) | 8080 | Public via `${ADMIN_SUBDOMAIN}.imurph.com` (basic auth) |
| Podcast Asset Finder | — (Traefik only) | 8000 | `podfiles.imurph.com` via Cloudflare Access |
| How-To Pilot | — (Traefik only) | 80 | `howto.imurph.com` via Cloudflare Access; see `docker/howto/README.md` |
| Uptime Kuma | — (Traefik only) | 3001 | Public via `uptime.imurph.com` |
| Directus DB | — (internal only) | 5432 | `app-net` only, no host binding |

> All host bindings are now either Traefik (Cloudflare-gated) or the
> Tailscale IP — nothing binds a service directly to `0.0.0.0` anymore.
> Directus went the other direction on 2026-07-22: public via Traefik at
> `cms.imurph.com` so the Astro site and other API consumers can reach it
> without Tailscale workarounds. Its protection is credentials + 2FA at the
> app layer and Cloudflare-only ingress at the network layer.

### n8n AI Assistant services

The AI Assistant depends on two private stacks. Both are attached to
`app-net`, and neither has a `ports:` mapping or Traefik labels.

| Component | Internal URL | Authentication | Purpose |
|---|---|---|---|
| Sandbox API | `http://sandbox-api:8080` | API key from `/docker/n8n-sandbox/.env` | Accepts code-execution requests from n8n |
| Sandbox runner | `http://sandbox-runner-1:8080` | Mutual TLS plus runner credentials | Runs isolated workloads inside privileged Docker-in-Docker |
| SearXNG | `http://searxng:8080` | No n8n API key required | Provides web search through its JSON API |

The sandbox stack contains three Compose services:

- `sandbox-certs` runs once to generate the mutual-TLS certificates.
- `sandbox-api` is the control plane n8n connects to.
- `sandbox-runner-1` is the privileged Docker-in-Docker worker.

Sandbox credentials are generated only on the VPS in
`/docker/n8n-sandbox/.env`. SearXNG's private server secret lives in
`/docker/searxng/.env`; it is not the API key requested by n8n. The SearXNG
credential in n8n needs only the API URL `http://searxng:8080`, and
`docker/n8n/docker-compose.yml` also supplies that URL through
`N8N_INSTANCE_AI_SEARXNG_URL`.

From the VPS, verify both services from the same network context n8n uses:

```bash
docker exec n8n-n8n-1 wget -qO- http://sandbox-api:8080/healthz
docker exec n8n-n8n-1 wget -qO- 'http://searxng:8080/search?q=n8n&format=json'
```

The expected sandbox response is `{"status":"ok"}`. The SearXNG response
should be JSON containing a non-empty `results` array. Individual upstream
search engines may occasionally return rate-limit or CAPTCHA errors; SearXNG
continues using the engines that remain available.

> `sandbox-runner-1` runs with `privileged: true`. Treat it as equivalent to
> root access on the host and never expose it publicly. n8n currently
> positions its self-hosted sandbox for development and testing and recommends
> Daytona for production workloads; see the
> [n8n AI Assistant setup guide](https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-ai-assistant).

### Podcast Asset Finder

Podcast Asset Finder is the browser interface from the separate `podcast-rss`
application repository. It runs at `https://podfiles.imurph.com` and gives the
creative team a non-Terminal workflow for finding RSS feeds, show artwork,
episode audio, and publisher-provided transcripts.

Cloudflare Access is the identity boundary. Its reusable allow policy contains
the approved work-email addresses and uses one-time PIN authentication with a
one-week session. The app has no user database or password middleware. Do not
copy the email allowlist into this repository; membership is managed in the
Cloudflare dashboard.

Traefik routes HTTPS traffic to port 8000 over `app-net`; the service publishes
no host port. The container runs as a non-root user with a read-only filesystem,
has no persistent data, and exposes `/healthz`. See
`docker/podcast-rss/README.md` for deployment, verification, and rollback.

---

## 4. Infrastructure Volume Mapping

Named Docker volumes hold the actual application data; compose files and
this repo hold the config. For backups, the volumes below are what matters
— back up the volume, not the `/docker/<service>` directory itself (which is
mostly just the compose file + `.env`).

| Service | Volume(s) | Mounted To | Notes |
|---|---|---|---|
| Traefik | `traefik_data` (external) | `/letsencrypt` | ACME certs |
| n8n | `n8n_data` (external) | `/home/node/.n8n` | Workflows, credentials, DB — backed up by `backup_n8n.sh` |
| n8n | bind mount `/local-files` | `/files` | Host-shared files dir |
| n8n Sandbox | `n8n-sandbox_sandbox-tls` (compose-managed) | `/tls` | Mutual-TLS certificates for the sandbox API and runner |
| Ollama | `ollama_models` (external) | `/root/.ollama` | Pulled model weights |
| Open WebUI | `open_webui_data` (external) | `/app/backend/data` | Chat history, users |
| Directus | `directus_db_data` (external) | `/var/lib/postgresql/data` | Postgres data dir |
| Directus | `directus_uploads` (external) | `/directus/uploads` | User-uploaded assets |
| Shlink | `shlink_data` (compose-managed) | `/etc/shlink/data` | SQLite DB, short-URL data |
| Uptime Kuma | `uptime-kuma_data` (explicit name) | `/app/data` | Monitors, status history, and notification settings |

All volumes live under Docker's default storage location on the host
(`/var/lib/docker/volumes/`). Explicit volume names map directly to
`docker volume ls`; Compose-managed volumes receive a project-name prefix.

---

## 5. Maintenance & Automation Pipeline

`scripts/maintain.sh` is the update pipeline for the whole VPS. It's
deployed at `/docker/maintain.sh` on the host and runs identically whether
you SSH in and run it yourself or trigger it remotely via the n8n webhook
(`vps_maintenance_dasshboard`, the "Bookmark Me" webhook trigger).

What it does, in order:

1. **OS update** — `apt-get update && upgrade -y && autoremove -y`
2. **Every docker-compose stack** — loops over every `/docker/*/docker-compose.yml`
   it finds, running `docker compose pull && docker compose up -d` in each.
   Backup directories ending in `.backup`, `.backup-*`, `.bak`, or `.bak-*`
   are skipped, as are directories containing a `.maintenance-ignore` file.
   Add a new service directory and the next run picks it up automatically.
3. **Image cleanup** — `docker image prune -f`

Each step is tracked independently: a failure in one service's update
doesn't stop the others from running, and the script ends with a clear
`RESULT: SUCCESS` or `RESULT: FAILED` line summarizing the whole run.

Every run — interactive or webhook-triggered — writes a full copy of its
output to `/var/log/vps-maintenance/last-run.log` on the host, in addition
to printing it live if run from a terminal. That log file is what the n8n
workflow reads back to build the email report (see below), and it's also
the first place to check after any run: `cat /var/log/vps-maintenance/last-run.log`.

### The n8n workflow: dispatch → wait → read back

n8n itself is one of the services this script updates, which creates a
chicken-and-egg problem: the very process running the maintenance workflow
can get torn down mid-script when its own container gets recreated. Blocking
on a single SSH command for the whole run (the original design) meant that
when n8n's own container got killed, the SSH connection carrying that
command died with it — the *script kept running* on the host, but n8n lost
the connection and never received the final output. That's what caused an
early run to leave `n8n-n8n-1` stuck in a `Created` state and `flow.imurph.com`
returning a 404 until it was manually restarted.

The fix is to stop treating that connection as load-bearing. The workflow
runs in three stages:

1. **Dispatch** (`Dispatch Maintenance Script`, SSH node) — starts the script
   fully detached from the SSH session (`nohup ... & disown`) and returns
   immediately. Because the whole script — not just the n8n update step — is
   detached before it runs, n8n restarting itself partway through no longer
   matters; the script is already an independent process on the host by then.
2. **Wait** (`Wait for Maintenance to Finish`) — a plain 180-second delay,
   long enough for the full OS and Docker stack update to finish.
3. **Read back** (`Read Maintenance Report`, SSH node) — a brand-new SSH
   connection (n8n is back up by now) that just runs `cat
   /var/log/vps-maintenance/last-run.log` and returns the completed report.

`Format Summary Output` then checks the log text for the literal string
`RESULT: SUCCESS` to set a clean `status` field, and `Send a message`
(Gmail) emails the full report to `vps@mikemurphy.ai`.

### Webhook Trigger Security

The webhook trigger (`Webhook Trigger (Bookmark Me)` node) was originally
an **unauthenticated `GET`** endpoint — anything that requested the URL
(bots, link-preview crawlers, scanners) could fire a full OS + container
update with no confirmation. That's exactly what happened on the first
run: the pipeline executed before anyone intentionally triggered it.

Fixed by adding **Basic Auth** to the webhook node in n8n, with the
credential stored only inside n8n's own credential store — never in this
repo. The method was kept as `GET` so it still works as a one-click
bookmark; the difference is n8n now challenges every request with a
username/password before it'll execute anything. An unauthenticated request
gets rejected outright instead of running maintenance.

Note: embedding the credentials directly in the URL
(`https://user:pass@flow.imurph.com/...`) does **not** reliably work as a
bookmark — modern browsers (Chrome, Safari, Edge) strip embedded
credentials from URLs on direct navigation as an anti-phishing measure. Use
the plain URL instead and let the browser's native sign-in prompt handle
it — see "Triggering a Maintenance Run" below.

### Triggering a Maintenance Run

There are three ways to kick off a run, all calling the exact same
`/docker/maintain.sh` and writing to the same
`/var/log/vps-maintenance/last-run.log`. No additional setup is needed for
any of them — SSH access and the webhook's Basic Auth credential already
exist.

| Method | Where you see it happen | Email report? | Command / URL |
|---|---|---|---|
| Direct SSH | Live in your terminal | No — this path never touches n8n | `ssh hostinger-vps 'bash /docker/maintain.sh'` |
| curl (webhook) | Terminal, instant acknowledgment only | Yes, ~3 min later | `curl -u mike:<password> https://flow.imurph.com/webhook/trigger-vps-maintenance` |
| Browser bookmark | Browser, instant acknowledgment only | Yes, ~3 min later | `https://flow.imurph.com/webhook/trigger-vps-maintenance` (bookmark the plain URL, no embedded credentials) |

**Direct SSH** is the fastest way to watch a run happen and get an
immediate pass/fail without waiting on anything — good for "I'm already at
my terminal and want to see it now." It does not go through n8n, so no
email gets sent.

**curl or the browser bookmark** both go through the n8n webhook
(dispatch → wait 180s → read log → email). Use whichever is more
convenient for where you are; they behave identically. The password lives
in n8n's Basic Auth credential, not in this repo — the first time you use
the browser bookmark, most browsers offer to save the password so
subsequent clicks don't require retyping it.

The webhook node's **Respond** setting is deliberately set to
**"Immediately"** rather than "When Last Node Finishes" — the HTTP
response comes back the instant the request is received, fully decoupled
from the workflow's ~3-minute run. This avoids holding a curl/browser
connection open for minutes (real risk of a proxy or client timeout) and
matches the intended UX: trigger it, walk away, get emailed the result.

**Optional convenience — shell aliases** (add to `~/.zshrc`):
```bash
alias vps-maintain='ssh hostinger-vps "bash /docker/maintain.sh"'
alias vps-maintain-remote='curl -u mike:<password> https://flow.imurph.com/webhook/trigger-vps-maintenance'
```
This stores the webhook password in plaintext in your dotfile — fine for a
personal single-user VPS, but worth knowing if `~/.zshrc` ever gets synced
or shared somewhere.

---

## 6. Useful Cheat Commands

Quick inspection commands for `ssh hostinger-vps`:

**All containers, clean table view:**
```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

**Check the running n8n version:**
```bash
docker exec -it n8n-n8n-1 n8n --version
```

**Tail a service's logs:**
```bash
docker compose -f /docker/<service>/docker-compose.yml logs -f
```

**Redeploy a single service after editing its compose file:**
```bash
cd /docker/<service> && docker compose up -d
```

**List all named volumes (cross-check against §4):**
```bash
docker volume ls
```

**Manually trigger the maintenance pipeline (runs live in your terminal):**
```bash
bash /docker/maintain.sh
```

**Check the result of the last maintenance run (webhook or manual):**
```bash
cat /var/log/vps-maintenance/last-run.log
```

---

## 7. Security & Reliability TODO

A living checklist of everything identified as a gap during setup, so this
infrastructure keeps moving toward best practice instead of these findings
living only in a chat log. Check items off as they're done; add new ones as
they come up. Roughly ordered by priority within each group.

### Security

- [x] Restrict **Ollama** to Tailscale-only. Was publishing on `0.0.0.0:11434`.
      Fixed: `docker/ollama/docker-compose.yml` port mapping is now
      `"<TAILSCALE_IP>:11434:11434"`, matching Directus. Verified
      unreachable from the public IP, still reachable over Tailscale and via
      internal `app-net` container DNS.
- [x] Restrict **Open WebUI** the same way — now `"<TAILSCALE_IP>:8080:8080"` in
      `docker/open-webui/docker-compose.yml`. Same verification as Ollama.
- [x] **Expose Directus publicly at `cms.imurph.com`** (2026-07-22) — was
      Tailscale-only, which made API access from the Astro site a rewiring
      maze. Removed the `<TAILSCALE_IP>:8055` port binding, added the standard
      Traefik label block, set `PUBLIC_URL=https://cms.imurph.com`. Let's
      Encrypt cert issued and verified (`/server/ping` → `pong`). App-layer
      protection: strong 1Password-managed credentials + 2FA. Previous
      compose kept on the host as
      `docker-compose.yml.pre-public-20260722`.
- [x] **Cloudflare-only origin firewall** (2026-07-22) — within seconds of
      Directus going public, a scanner bot was probing it for exposed
      secrets (all 404s) by hitting the origin IP directly, bypassing
      Cloudflare entirely. Fixed with `scripts/cf-lockdown.sh`: a `CF-ONLY`
      iptables chain hooked into `DOCKER-USER` (Docker published ports
      bypass ufw's INPUT chain, so ufw alone can't gate them) that drops
      new connections to 80/443 on `eth0` unless the source is one of
      Cloudflare's 15 published IPv4 ranges. Deployed at
      `/usr/local/sbin/cf-lockdown.sh` with `cf-lockdown.service`
      (reapplies on boot, after Docker) and `cf-lockdown.timer` (weekly
      range refresh). Also deleted ufw's IPv6 allow rules for 80/443 —
      Cloudflare reaches the origin via the IPv4 A-record only, so the v6
      listener was pure scanner surface. Verified: direct-to-IP requests
      time out on 80 and 443, all `*.imurph.com` services fine, SSH
      untouched.
- [x] **Protect Podcast Asset Finder with Cloudflare Access** (2026-09-02) —
      `podfiles.imurph.com` uses an exact email allowlist, one-time PIN login,
      and a one-week session. Removed the temporary Traefik BasicAuth
      middleware after confirming both anonymous redirects and authenticated
      app access. The app publishes no host port and remains reachable only
      through Cloudflare and Traefik.
- [ ] Enable Cloudflare **Bot Fight Mode** (dashboard: Security → Bots) —
      now that the origin only accepts Cloudflare traffic, CF-level bot
      filtering is mandatory for bots, not optional. Won't affect API
      traffic.
- [ ] Confirm SSH password auth is disabled (key-only) —
      `grep PasswordAuthentication /etc/ssh/sshd_config` should show `no`.
- [x] Install/confirm `fail2ban` is active for SSH brute-force protection.
      Confirmed: installed, enabled on boot, `sshd` jail active and watching
      `/var/log/auth.log`.
- [x] Confirm unattended security updates are actually applying. Confirmed:
      `apt-daily-upgrade.timer` + `unattended-upgrades` really do install
      (not just download) — logs show real packages applied on 7/14, 7/15,
      7/16. `Allowed-Origins` is Ubuntu's stock default (base release +
      `-security` + ESM-security, excludes general `-updates`). Also enabled
      `Automatic-Reboot "true"` at `04:00` so kernel patches actually take
      effect (they weren't rebooting before) — all containers are
      `restart: unless-stopped` so they come back up on their own.

### Backups

Four stateful application services (n8n, Directus, Shlink, Uptime Kuma)
have automated local backups via staggered nightly cron, each now also
synced offsite to Mike's NAS over Tailscale (see below).

- [x] **Uptime Kuma** (2026-10-22) — added
      `docker/uptime_kuma/backup_uptime_kuma.sh` (deployed to
      `/docker/uptime-kuma/`). Kuma writes `kuma.db` constantly in WAL
      mode, so instead of a raw volume tar it takes a SQLite online
      `.backup` in a throwaway alpine container, runs `PRAGMA
      integrity_check` on the snapshot, and archives it with the
      `upload`/`screenshots`/`docker-tls` dirs into
      `/var/backups/uptime-kuma/` (~58MB compressed). Cron: `10 3 * * *`.
      "Backup: uptime-kuma" push monitor (id 25) cloned from
      `Backup: shlink` via direct DB insert (93600s heartbeat, Telegram);
      push URL in `/docker/uptime-kuma/.env`, gitignored. Verified live:
      offsite archive confirmed with `rclone check --download`, push
      heartbeat recorded as up. At the same time moved the old manual
      `kuma.db.bak.*` copies (~700MB) out of the live volume to
      `/var/backups/uptime-kuma-legacy/`. Since Kuma 2.x drops JSON
      backup/restore, this data-dir archive is the restore path: stop
      Kuma, untar into `uptime-kuma_data`, start.

- [x] **YOURLS** *(decommissioned 2026-10-22 — see Operational hygiene)* — added `docker/yourls/backup_yourls.sh`: `mysqldump
      --no-tablespaces` of the `yourls` DB via `docker exec yourls-db`
      (password read from the container's own `MYSQL_PASSWORD` env var, never
      duplicated into the script), gzipped. `--no-tablespaces` avoids a
      harmless but noisy privilege warning from mysqldump running as a
      non-root DB user. No separate uploads volume, unlike Directus. Tested
      live (1.6KB dump — small install, expected). Cron: `10 3 * * *`.
      Created a matching "Backup: yourls" push monitor in Uptime Kuma
      (same direct-DB-insert approach as the `yourls.imurph.com` HTTP
      monitor above; push token in `docker/yourls/.env`, gitignored),
      93600s heartbeat, attached to the Telegram channel. Verified live:
      offsite archive confirmed on the NAS, Kuma monitor flipped to up.

- [x] **Directus** — added `docker/directus/backup_directus.sh`: `pg_dump`
      of `directus_db_data` via `docker exec directus-db pg_dump`, plus a
      tar of `directus_uploads`. Tested live: both produced real,
      non-empty output (7MB dump, 90MB uploads archive).
- [x] **Obsidian** *(decommissioned 2026-10-04 — see Operational hygiene)* — added `docker/obsidian/backup_obsidian.sh`. Note: the
      real volume is `obsidian_obsidian_data` (Compose project-prefixed,
      since `obsidian_data` has no explicit `name:` — see the compose
      file's own comment on this). Tested live, captured the real vault
      (270MB).
- [x] **Shlink** — added `docker/shlink/backup_shlink.sh`. Same
      project-prefix gotcha: real volume is `shlink_shlink_data`, not
      `shlink_data`. Tested live (738KB).
- [x] Added staggered cron entries in root's crontab (`/docker/n8n` was
      already `0 2 * * *`): Directus `10 2`, Obsidian `40 2`, Shlink `55 2`.
- [x] **Offsite sync via rclone → NAS** (2026-07-31) — installed `rclone`
      (apt, v1.60.1) on the VPS and configured an SFTP remote (`vault-nas`)
      pointing at Mike's UGREEN NAS "vault" over Tailscale (`<TAILSCALE_IP_NAS>`),
      authenticating as a dedicated `vps-backup` NAS user via SSH key
      (`/root/.ssh/vault_nas_backup`, no password stored anywhere).
      Destination: `vault-nas:/Vault/Backups/Hostinger VPS/<service>`. Note:
      the NAS's SFTP subsystem is chrooted to what a plain shell sees as
      `/volume1` — paths must drop that prefix (`/Vault/...`, not
      `/volume1/Vault/...`) when addressed through rclone/SFTP. Two rclone
      remote options were needed to work around this NAS's SFTP server:
      `use_fstat = true` (server doesn't support the `fstat` op rclone tries
      first) and `disable_hashcheck = true` (rclone's post-write MD5 check
      runs `md5sum` over an *unchrooted* shell-exec channel that doesn't see
      the same paths as the chrooted SFTP session — safe to skip since each
      script already writes its own `sha256sums.txt`). **Also caught a
      pre-existing silent failure**: all four scripts had rclone's
      `--log-file-format "date,time"` flag, which doesn't exist in the
      apt-packaged rclone version — every offsite sync had been failing
      outright since the scripts were written, but the trailing `|| true`
      swallowed the error and the script still logged "Backup completed
      successfully." Removed the flag; offsite sync now genuinely runs and
      was verified live for all four services (real archives confirmed on
      the NAS via `rclone lsl`). A cloud remote (Backblaze B2 or similar) as
      a second offsite layer remains a deliberately separate, later task.
- [x] Commit the new backup scripts to this repo (mirroring
      `docker/n8n/backup_n8n.sh`).
- [x] **Cron job monitoring via Uptime Kuma Push monitors** (2026-07-31) —
      considered deploying Healthchecks.io as its own stack, but Uptime Kuma
      already has a built-in Push monitor type that does the same
      dead-man's-switch job with zero new infrastructure, reusing the
      existing Telegram alert channel (see Monitoring below). Created one
      Push monitor per backup job — `Backup: n8n`, `Backup: directus`,
      `Backup: obsidian`, `Backup: shlink` — each with a 93600-second
      (26 hour) heartbeat interval: enough slack for an occasional slow run
      without a false alarm, tight enough to catch a fully missed night
      within ~2 hours of the next scheduled run. Each script `curl`s its
      monitor's push URL as the very last line, only reached after the
      whole run (local backup + offsite sync) completes without a fatal
      error; a failed or skipped night simply produces no ping, and
      Kuma/Telegram flags it once the window elapses. Verified live for all
      four.

#### Adding backups for a new service

`maintain.sh` auto-updates any new `/docker/*/docker-compose.yml` it finds
(see §5) — but backups don't happen automatically. When a new service goes
on the VPS:

1. **Write the backup script** — `docker/<service>/backup_<service>.sh`.
   Copy the closest existing pattern: `backup_shlink.sh` for a simple
   named-volume tar, `backup_directus.sh` if the service is Postgres-backed
   (dump + separate uploads/data-volume tar). Update `VOLUME_NAME` /
   `DB_CONTAINER` and the archive naming. **Confirm the real volume name
   first** with `docker volume ls` — Compose project-prefixes volumes that
   don't have an explicit `name:` set (e.g. `obsidian_data` in the compose
   file became `obsidian_obsidian_data` on disk).
2. **Point the offsite copy at the existing NAS remote** — no new NAS-side
   setup needed: `rclone copy "$BACKUP_DIR" "vault-nas:/Vault/Backups/Hostinger VPS/<service>"`
   (and the matching `rclone delete ... --min-age`), same as the four
   scripts above.
3. **Create an Uptime Kuma Push monitor** for it (Monitor Type: Push, 93600s
   heartbeat interval, Telegram notification on) and add
   `curl -fsS -m 10 "$KUMA_PUSH_URL"` as the last line of the script's
   success path.
4. **Add a staggered cron entry** in root's crontab on the VPS
   (`crontab -e`) — pick a time slot after the last one (currently ends at
   `55 2`, i.e. 2:55 AM).
5. **Deploy it** — there's no auto-deploy pipeline yet (see the Operational
   Hygiene TODO), so this repo and the VPS only match after an explicit
   copy:
   ```bash
   scp docker/<service>/backup_<service>.sh hostinger-vps:/docker/<service>/backup_<service>.sh
   ssh hostinger-vps 'chmod +x /docker/<service>/backup_<service>.sh'
   ```
6. **Test it live** before trusting it to cron:
   `ssh hostinger-vps 'bash /docker/<service>/backup_<service>.sh'`, then
   confirm the archive landed on the NAS
   (`rclone lsl "vault-nas:/Vault/Backups/Hostinger VPS/<service>"`) and the
   Kuma monitor flipped to up.
7. **Update the docs** — add the volume to §4's table, the script to §2's
   tree, and check it off in this section.

### Monitoring

- [x] Actually deploy Uptime Kuma — live at `https://uptime.imurph.com`.
- [x] Configure it to monitor every public URL (flow, obs, chat, both
      Shlink subdomains) plus internal services over `app-net` — Ollama,
      Open WebUI, and Directus are monitored via internal container DNS
      (e.g. `http://ollama:11434`) rather than public IP, since Kuma runs
      on the same host and would otherwise round-trip through `ufw`
      pointlessly. Plus a TCP:22 host-level monitor for the VPS itself.
- [x] Set up an alert channel — Telegram bot configured and receiving
      notifications.
      immediately instead of being discovered by accident.
- [x] **Actually attach that alert channel to the real monitors**
      (2026-08-26) — discovered while investigating the outage above:
      Kuma's `n8n` monitor (a proper HTTP check hitting
      `https://flow.imurph.com` every 60s, not just a container-alive
      ping) had correctly flagged the 526 failures within ~30 minutes of
      the cert expiring, but nothing ever notified anyone — it has zero
      notification channels attached. Checked every monitor: 9 of 14
      active ones (`n8n`, `VPS Host`, `Obsidian`, `cv-rag`, `Shlink`,
      `Uptime Kuma` itself, `Directus`, plus `Open-WebUI` and `Ollama`)
      had no notification wired up; only the low-signal Push
      "Backup: X" monitors, `Shlink-Admin`, and `Excalidraw` were
      actually connected to "My Telegram Alert". Fixed by inserting the
      missing rows directly into Kuma's `monitor_notification` table in
      its sqlite DB (backed up first to
      `/docker/uptime-kuma/kuma.db.bak.<timestamp>`) for the 7 monitors
      with a real public/internal endpoint to alert on: `n8n`,
      `VPS Host`, `Obsidian`, `cv-rag`, `Shlink`, `Uptime Kuma`,
      `Directus`. Left `Open-WebUI` and `Ollama` unattached — both
      internal-only (Tailscale/container-network), no public endpoint
      worth paging on.
- [x] Add a Kuma monitor for `yourls.imurph.com` (2026-09-08; removed
      with YOURLS 2026-10-22) — inserted
      directly into `kuma.db` (same approach as the notification-wiring fix
      above), same pattern as the `Shlink` monitor: HTTP check against
      `https://yourls.imurph.com/admin/`, 60s interval, attached to "My
      Telegram Alert" via `monitor_notification`. DB backed up first to
      `/docker/uptime-kuma/kuma.db.bak.<timestamp>`. Verified live —
      monitor id 23 is passing (`200 - OK`).

### Operational hygiene

- [x] Pin floating image tags to specific versions, so `maintain.sh`'s
      `docker compose pull` becomes a no-op instead of a silent surprise
      upgrade (this already happened once: n8n auto-upgraded 2.29.10 →
      2.30.7 mid-conversation). Pinned to whatever was already running, so
      no behavior changed today — future upgrades now require deliberately
      editing the tag:
      - Ollama: `:latest` → `:0.32.1`
      - n8n: untagged (=`:latest`) → `:2.35.7`
      - Obsidian: `:latest` → `:v1.12.7-ls138`
      - Shlink: `:stable` → `:5.1.5`, Shlink Web Client: `:stable` → `:4.8.0`
      - Open WebUI: `:main` → pinned by **digest**
        (`@sha256:a26effeb...`) since the registry has no version tag
        matching the running `0.10.2` build
      - Directus: `:12` → `:12.1.1` (2026-07-22, pinned as part of the
        `cms.imurph.com` public exposure — a floating major tag on a
        newly public service meant `maintain.sh` could silently upgrade it)
      - n8n Sandbox API, runner, and nested sandbox image: pinned by digest
      - SearXNG: pinned by digest
      - Not touched: Postgres/Redis/pgvector (pinned to major version,
        lower risk, separate tier of precision).
- [x] **Fixed a silent `flow.imurph.com` TLS outage** (2026-08-26) —
      Cloudflare had been returning 526 ("invalid origin cert")
      intermittently for ~17 hours before it was caught manually (see the
      Monitoring gap below). Root cause: `acme.json` held two dead
      certificate entries left over from before the domain moved off
      `mikevps.com` (`n8n.mikevps.com`, `flow.mikevps.com`), each bundling
      `flow.imurph.com` in as a co-SAN. Those domains' Cloudflare zones no
      longer exist under the current API token, so Let's Encrypt's DNS-01
      renewal for those bundles failed every cycle — and Traefik's SNI
      cert matching would non-deterministically serve one of those
      expired, poisoned certs for `flow.imurph.com` instead of its own
      independently-issued, cleanly-renewing one. A plain container
      restart looked like it fixed things (picked the good cert that
      time) but didn't address the poisoning, so it silently came back.
      Fixed by removing the two poisoned entries — plus one fully-dead,
      unused `n8n.srv933076.hstgr.cloud` entry — directly from `acme.json`
      on the VPS (backed up first to
      `/docker/traefik/acme.json.bak.<timestamp>`). `flow.imurph.com` now
      resolves to a single clean cert (valid to 2026-09-30) and should
      self-renew normally going forward. Also checked `go.mikemurphy.ai`'s
      cert (similarly bundled with `shlink.imurph.com`) — not at the same
      risk, since `mikemurphy.ai`'s zone is still valid under the token.
- [x] **Upgrade Traefik v2.11 → v3.7.11** (2026-08-26) — bundled into the
      outage fix above while already in the reverse-proxy config. v3
      removes the `SSLRedirect`, `SSLHost`, `SSLForceHost`,
      `SSLTemporaryRedirect`, and `featurePolicy` options from the Headers
      middleware (HTTPS redirect is already handled at the entrypoint
      level via `entrypoints.web.http.redirections`, so no behavior
      change) — removed the now-invalid `SSLRedirect=true` label from all
      6 services that had it: n8n, Obsidian, both Shlink routers, Uptime
      Kuma, Excalidraw, Directus. Also added `--log.level=INFO`
      (previously defaulted to ERROR-only, which is exactly why the cert
      poisoning above went unnoticed for weeks — nothing ever logged a
      *successful* renewal to compare against). Verified every proxied
      domain still returns its expected status and security headers
      post-upgrade. Traefik now pinned the same way as the other
      minor-version-pinned images (`:v3.7`, floating patch releases).
- [x] `docker/directus/docker-compose.yml` in this repo had drifted from
      the VPS: the live version has `CORS_ENABLED`, `CORS_ORIGIN`,
      `CORS_METHODS`, `CORS_ALLOWED_HEADERS`, and three `MCP_OAUTH_*` env
      vars (per a `.bak-cors-20260727220920` on the VPS, so added
      2026-07-27) that were never synced back to this repo. Unrelated to
      the Traefik work — noticed while diffing for that sync. Synced
      (2026-08-26); confirmed the file is now byte-identical to the live
      version. The three `MCP_OAUTH_*` vars were already present in this
      repo's `docker/directus/.env`, so nothing else needed updating.
- [ ] Set an n8n execution-data retention policy
      (`EXECUTIONS_DATA_PRUNE` and related env vars) — a restart during
      setup surfaced 2,523 unfinished executions with no automatic
      cleanup in place.
- [x] **Decommissioned Obsidian** (2026-10-04) — `obs.imurph.com` is gone.
      Stopped the container, took a final tarball of `obsidian_obsidian_data`
      (`obsidian_data_FINAL_20261004_143254.tar.gz`, 288MB, sha256
      `b24c4991…01ff6`) plus a tarball of the old `/docker/obsidian` config
      (`obsidian_config_FINAL_20261004.tar.gz`, includes `.env`). Both are in
      `vault-nas:/Vault/Backups/Hostinger VPS/obsidian` (verified with
      `rclone check --download`) alongside the nightly archives from 9/5–10/4;
      the data tarball is also kept on the VPS in `/var/backups/obsidian/`.
      Then `docker compose down`, removed the volume, the image, the
      `/docker/obsidian` dir, and the `40 2` backup cron entry. Deleted the
      `Obsidian` and `Backup: obsidian` Kuma monitors (ids 3 and 19) from
      `kuma.db` with `foreign_keys=ON` so heartbeats/notification rows
      cascaded (DB backed up first). Cloudflare DNS record removed by Mike.
      To restore: `docker volume create obsidian_obsidian_data`, then untar
      the archive into it with a throwaway alpine container.
- [x] **Decommissioned YOURLS** (2026-10-22) — `yourls.imurph.com` is gone.
      Never used (1.6KB DB), and its `yourls:1.9-apache` image ran PHP
      8.3.19 under mod_php, the highest-risk setup for PHP2Shell
      (CVE-2026-109618/109619), so it was removed rather than patched.
      Took a final dump (`yourls_db_FINAL_20261022_015818.sql.gz`, sha256
      `2b06a3d3…266b3`) plus a tarball of the old `/docker/yourls` config
      (`yourls_config_FINAL_20261022.tar.gz`, includes `.env`). Both are in
      `vault-nas:/Vault/Backups/Hostinger VPS/yourls` (verified with
      `rclone check --download`) alongside the nightly dumps, and kept on
      the VPS in `/var/backups/yourls/`. Then `docker compose down`, removed
      the `yourls_db_data` volume, the `yourls:1.9-apache` and `mysql:8.4`
      images, the `/docker/yourls` dir, and the `10 3` backup cron entry
      (crontab backed up to `/root/crontab.bak.<timestamp>`). Deleted the
      `YOURLS` and `Backup: yourls` Kuma monitors (ids 23 and 24) from
      `kuma.db` with `foreign_keys=ON` (DB backed up first). Cloudflare DNS
      record removed by Mike. To restore: recreate the compose stack from
      git history, then pipe the dump into `mysql` in the `yourls-db`
      container.
- [x] **Patched Shlink for PHP2Shell** (2026-10-22) — the official image
      (5.1.5 on PHP 8.5.7) was vulnerable and no patched `shlinkio/shlink`
      existed yet, so built one on the VPS: `git clone --branch v5.1.7`
      into `/root/build/shlink-5.1.7` with two Dockerfile edits —
      `FROM php:8.5.12-alpine3.23` (Shlink's `php:8.5-alpine3.22` base is no
      longer updated upstream and stays on 8.5.7) and
      `rr get ... --filter=2025.1.15` (unpinned, it pulled RoadRunner 3.0.1;
      the official 5.1.7 image ships 2025.1.15). Result
      `shlink-local:5.1.7-php8.5.12`: same 47 PHP extensions and identical
      `.rr.yml`/entrypoint as the official image. Rehearsed against a copy
      of the live SQLite DB on an isolated network first — migrations
      unchanged (10), all 277 short URLs returned the exact original URL in
      `Location`. Swap took ~15s of downtime; cold pre-upgrade backup
      `shlink_data_PRE-UPGRADE_20261022_021020.tar.gz` is in
      `/var/backups/shlink/` and on the NAS (verified with
      `rclone check --download`). **Rollback:** set the compose image to
      `shlink-rollback:5.1.5-php8.5.7` (old image, still tagged on the VPS)
      and `docker compose up -d --no-deps shlink` — no schema changes, so
      the data is compatible either way.
- [x] **Update checks for Directus and n8n** (2026-10-22) — no release of
      either ships Node patched for the 2026-10-21 security release yet
      (Directus 12.5.0 → Node 22.23.3; n8n 2.44.5 stable → Node 26.10.0),
      so there was nothing to upgrade to. `scripts/check_image_update.sh`
      (installed as `/usr/local/sbin/check_image_update.sh`) resolves the
      project's stable floating tag (`latest` / n8n's `stable`) to its
      `X.Y.Z` tag by digest — so n8n betas published as plain versions are
      ignored — reads that image's `NODE_VERSION` from the registry config
      blob (no pull), and pushes to the app's "Update: <name>" Kuma monitor
      (Telegram): **up** while waiting, **down** once a newer release ships
      Node >= 22.23.4 / 24.22.1 / 26.12.1 (`MIN_NODE` in the script —
      update it for future Node advisories). Cron:
      - Directus — `0 13 * * 1` (Mondays 9am ET), monitor id 26, 8-day heartbeat
      - n8n — `5 13 * * *` (daily; n8n is the most exposed to the Node
        Brotli/TLS bugs via HTTP Request nodes), monitor id 27, 26h heartbeat
      - Shlink — `10 13 * * *` with the `php` runtime arg, monitor id 28,
        26h heartbeat. Checks `PHP_VERSION` against PHP2Shell fixes
        (`MIN_PHP`: 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12). While the compose
        file ran the local `shlink-local` build, the script saw no official
        version and alerted as soon as *any* official stable release shipped
        patched PHP — it fired for 5.1.8 on 2026-10-22. Now that Shlink is
        back on the official image, it behaves like the others.

      Push URLs are `KUMA_UPDATE_PUSH_URL` in each app's `.env`, gitignored.
      Logs: `/var/log/<name>-update-check.log`.
      **Fix 2026-10-26:** the script now also reads the runtime version of
      the *current* tag and reports up ("up to date") once that's patched —
      before, n8n 2.44.7 raised a false "time to upgrade" while 2.44.6 was
      already on patched Node 26.12.1.
- [x] **Upgraded Directus 12.1.1 → 12.5.1** (2026-10-26, after the
      "Update: directus" alert) — Node 22.23.4 (patched). Release notes
      12.2.0–12.5.1 reviewed: none of the breaking changes apply (Astro uses
      plain REST `fetch`, not `@directus/sdk`; `/assets/<id>` without
      transforms; no policy `ip_access`; no custom CMD/extensions/
      `CACHE_SCHEMA_*`). Editors will see the 12.2 Tiptap WYSIWYG, which
      may lock a field read-only until a markup-normalization warning is
      confirmed. **A/B rehearsal:** 12.1.1 and 12.5.1 side by side, each on
      its own `pg_restore` of the live DB, on an `--internal` network
      (no egress, no Traefik), uploads mounted read-only. 4 migrations
      (106 → 110) ran cleanly; every Astro request (Field_Notes,
      Resources, Brand_Kit with Astro's exact `fields`/filter/sort, plus
      all 51 referenced `/assets/<id>` files) returned byte-identical
      responses with the real Astro token; podcast_episodes PATCH/POST
      behaved identically (via a throwaway admin token set only in the
      copies). **Live:** baseline of the 54 Astro responses through
      `cms.imurph.com`, stopped only the app container, cold
      `pg_dump` + uploads tar
      (`directus_*_PRE-12.5.1_20261026_133518.*`, VPS + NAS verified with
      `rclone check --download`), swap ~2 min downtime; all 54 responses
      identical to the baseline afterwards. A first attempt at 13:16 was
      aborted and 12.1.1 restarted (~11 min down) because the NAS was
      unreachable — see the NAS entry below. **Rollback:** compose →
      `directus/directus:12.1.1` (image still on the VPS), restore the
      PRE-12.5.1 dump into a fresh `directus` DB (migrations aren't
      reversible), `docker compose up -d --no-deps directus`.
- [x] **NAS offsite outage went unnoticed** (found 2026-10-26) — the NAS
      was unreachable over Tailscale on the nights of 10/25 and 10/26
      (`rclone ... couldn't connect SSH: i/o timeout` in
      `/root/rclone_backup.log`), but the backup scripts swallowed the
      failure (`rclone copy ... || true`) and still pushed "up" to Kuma.
      Caught up all five services once the NAS was back (0 differences).
      Fixed n8n/Directus/Shlink/Kuma backup scripts: a failed
      `rclone copy` now sets `OFFSITE_OK=0`, logs it, and pushes
      `status=down` with a message to the backup's Kuma monitor (Telegram)
      instead of "up". (stylelock's script already fails the run if its
      `rclone copyto` fails.)
- [x] **Upgraded Uptime Kuma 1.23.17 → 2.5.6** (2026-10-22) — v1 runs on
      Node 18 (EOL, no fix for the 2026-10-21 Node advisory). Rehearsed
      first on a copy of the data with `--network none` (so the copy
      couldn't check sites or send Telegram): aggregate-table migration
      took 12m52s, monitor config (ids, names, URLs, intervals, push tokens)
      hashed identical before/after. Real upgrade: paused the 03:10 Kuma
      backup cron, stopped Kuma, cold backup
      `uptime-kuma_data_PRE-V2_20261022_030924.tar.gz` (in
      `/var/backups/uptime-kuma/` + NAS, `rclone check --download`), set
      image to `louislam/uptime-kuma:2.5.6`, migration took 13m38s (~15 min
      with no monitoring). Verified: all 17 monitors UP, all 7 push
      monitors accepting pings, notifications intact, cron re-enabled.
      Data dir grew 207MB → 349MB (v2 aggregate tables).
      **Rollback:** compose back to `louislam/uptime-kuma:1`, stop Kuma,
      empty `uptime-kuma_data`, untar the PRE-V2 archive into it, start —
      v1 can't read the migrated DB, so the restore is required.
      **Note:** v2 changes the schema — the direct `kuma.db` INSERT recipes
      above were written for v1; prefer adding monitors via the UI now.
- [x] **Upgraded n8n 2.43.7 → 2.44.6** (2026-10-22, by Mike after the
      "Update: n8n" alert) — ships Node 26.12.1 (patched). Repo compose
      synced. (It had drifted 8 minor versions behind the VPS before
      2026-10-22 — keep `docker/n8n/docker-compose.yml` in sync on upgrade.)
- [x] **Switched Shlink back to official `shlinkio/shlink:5.1.8`**
      (2026-10-22, after the "Update: shlink" alert) — PHP 8.5.12, Alpine
      3.24. Note it ships **RoadRunner 3.0.1** (the major version the local
      build had pinned away from); upstream's `.rr.yml` and entrypoint are
      byte-identical to 5.1.7. Rehearsed on a copy of the live DB first:
      RR 3.0.1 started cleanly, migrations unchanged (10), all 277 short
      URLs returned the exact original URL in `Location`, REST API
      (list/visits/bad-key 401) worked with a throwaway rehearsal key. Cold
      backup `shlink_data_PRE-5.1.8_20261022_131740.tar.gz` (VPS + NAS,
      `rclone check --download`), then swap with ~15s downtime; verified
      publicly. Removed the vulnerable 5.1.5 image. **Rollback:** compose
      image → `shlink-local:5.1.7-php8.5.12` (still on the VPS) and
      `docker compose up -d --no-deps shlink`.
- [ ] After a week on 5.1.8 (~2026-10-29), remove the `shlink-local` image
      and `/root/build/shlink-5.1.7` from the VPS.
- [ ] Shlink web client is running `shlinkio/shlink-web-client:stable`
      but the compose file pins `4.8.0` — reconcile on next redeploy
      (static nginx app, not affected by PHP2Shell).
- [ ] Decide whether to build a simple deploy step (e.g., a script that
      `git pull`s this repo on the VPS and re-applies any changed compose
      file) so editing this repo actually updates the server, instead of
      today's manual `scp` + SSH process (see §5's note on this).
