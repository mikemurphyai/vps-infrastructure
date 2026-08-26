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
│   └── cf-lockdown.sh           # Cloudflare-only firewall for ports 80/443 (see §1)
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
    ├── obsidian/
    │   ├── docker-compose.yml
    │   └── backup_obsidian.sh    # obsidian_obsidian_data volume backup (local + offsite via rclone → NAS)
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
    └── uptime_kuma/
        └── docker-compose.yml    # live at uptime.imurph.com (see §7 Monitoring)
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
| Obsidian | — (Traefik only) | 3000 | Public via `obs.imurph.com` |
| cv-rag Streamlit | — (Traefik only) | 8501 | Public via `chat.imurph.com` |
| Shlink | — (Traefik only) | 8080 | Public via `${SUBDOMAIN}.imurph.com` + short domain |
| Shlink Web Client | — (Traefik only) | 8080 | Public via `${ADMIN_SUBDOMAIN}.imurph.com` (basic auth) |
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
| Obsidian | `obsidian_data` (compose-managed) | `/config` | Vault + app config |
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
   No stack is special-cased or hardcoded — add a new service
   directory and the next run picks it up automatically.
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

Four stateful application services (n8n, Directus, Obsidian, Shlink) have
automated local backups via staggered nightly cron, each now also synced
offsite to Mike's NAS over Tailscale (see below).

- [x] **Directus** — added `docker/directus/backup_directus.sh`: `pg_dump`
      of `directus_db_data` via `docker exec directus-db pg_dump`, plus a
      tar of `directus_uploads`. Tested live: both produced real,
      non-empty output (7MB dump, 90MB uploads archive).
- [x] **Obsidian** — added `docker/obsidian/backup_obsidian.sh`. Note: the
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
- [ ] Decide whether to build a simple deploy step (e.g., a script that
      `git pull`s this repo on the VPS and re-applies any changed compose
      file) so editing this repo actually updates the server, instead of
      today's manual `scp` + SSH process (see §5's note on this).
