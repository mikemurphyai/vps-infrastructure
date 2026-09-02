# Podcast Asset Finder deployment

This directory defines the VPS deployment for the `podcast-rss` browser app at
<https://podfiles.imurph.com>. Application source belongs in the separate
`podcast-rss` repository; this directory is the source of truth for its Traefik
and container configuration.

## Architecture

```text
Browser
  -> Cloudflare Access
  -> Cloudflare-proxied DNS and VPS firewall
  -> Traefik on app-net
  -> podcast-rss container on port 8000
```

Cloudflare Access provides one-time PIN authentication for an exact email
allowlist. The policy and approved identities are managed in Cloudflare and are
not stored in Git. Traefik handles HTTPS routing but does not provide a second
password prompt.

The container publishes no host port, stores no persistent data, runs as a
non-root user, and uses a read-only filesystem. Podcast assets are streamed to
the requesting browser and are not intentionally retained on the VPS.

## Files and live locations

| Purpose | Location |
|---|---|
| Tracked Compose configuration | `docker/podcast-rss/docker-compose.yml` |
| Tracked non-secret environment template | `docker/podcast-rss/.env.example` |
| Application source repository | `podcast-rss` |
| Live service directory | `/docker/podcast-rss` |
| Live application build context | `/docker/podcast-rss/app` |
| Docker network | `app-net` |
| Container port | `8000` |
| Health endpoint | `/healthz` |

The live `.env` currently contains only the non-secret routing values shown in
`.env.example`. Never add Cloudflare credentials or teammate email addresses to
it.

## First deployment

The shared `app-net` Docker network, Traefik, Cloudflare-proxied DNS record, and
Cloudflare Access application must already exist. On the VPS, create the service
and application directories:

```bash
ssh hostinger-vps 'mkdir -p /docker/podcast-rss/app'
```

From the root of this `vps-infrastructure` repository, copy the environment
template into place:

```bash
scp docker/podcast-rss/.env.example hostinger-vps:/docker/podcast-rss/.env
```

Then configure Cloudflare Access before treating the hostname as ready for use.
The environment file does not contain a password; authentication stays at
Cloudflare. Do not repeat this first-deployment copy if the live environment file
later gains service-specific settings that are not tracked in Git.

## Deploy an application update

First run the application tests from the root of the `podcast-rss` repository:

```bash
python3 -m unittest -v
```

Copy the application checkout to the VPS build context. Exclude local and Git
state:

```bash
rsync -az \
  --exclude .git \
  --exclude .venv \
  --exclude __pycache__ \
  ./ hostinger-vps:/docker/podcast-rss/app/
```

From the root of this `vps-infrastructure` repository, validate and copy the
deployment configuration:

```bash
docker compose \
  --env-file docker/podcast-rss/.env.example \
  -f docker/podcast-rss/docker-compose.yml \
  config --quiet

ssh hostinger-vps \
  'cd /docker/podcast-rss && if [ -f docker-compose.yml ]; then cp docker-compose.yml "docker-compose.yml.pre-deploy.$(date +%Y%m%d-%H%M%S)"; fi'

scp docker/podcast-rss/docker-compose.yml \
  hostinger-vps:/docker/podcast-rss/docker-compose.yml
```

The backup command intentionally stays on the VPS and does nothing when the live
Compose file does not exist during the first deployment.

Build and replace only this service:

```bash
ssh hostinger-vps \
  'cd /docker/podcast-rss && docker compose build && docker compose up -d'
```

## Verify

Confirm that the container becomes healthy:

```bash
ssh hostinger-vps \
  'cd /docker/podcast-rss && docker compose ps'
```

An unauthenticated request should redirect to Cloudflare Access:

```bash
curl -I https://podfiles.imurph.com/
```

Expect an HTTP redirect whose `Location` is on the Cloudflare Access domain.
Then open the site in an approved browser session and confirm that the Podcast
Asset Finder home page loads and can resolve a known show.

## Roll back

The app is stateless, so rollback means restoring the previous Compose file or
application source and rebuilding the container. Before overwriting a live
Compose file, keep a dated copy in `/docker/podcast-rss`. Do not remove the
current container until the replacement is healthy.

If a deployment fails, inspect recent logs first:

```bash
ssh hostinger-vps \
  'cd /docker/podcast-rss && docker compose logs --tail=100 podcast-rss'
```

Restore the known-good file or source tree, then run `docker compose build` and
`docker compose up -d` again. No volume restoration is required because this
service has no persistent application volume.

## Cloudflare Access changes

Access policy changes are separate from application deployment. Preserve these
properties when editing the Cloudflare application:

- Application hostname: `podfiles.imurph.com`
- Policy action: Allow
- Selector: exact approved email addresses
- Login method: one-time PIN
- Session duration: one week

After any policy change, test both an authenticated browser and a private or
signed-out browser. Never disable Access until another authentication boundary
is verified in front of the app.
