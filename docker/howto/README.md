# How-To Pilot review site

Private presentation gallery at https://howto.imurph.com, served by Nginx behind
Traefik and Cloudflare Access. Source assets are maintained in
`/Users/mikemurphy/Code/Projects/howto-pilot/presentation`.

## Deployment

- Remote directory: `/docker/howto`
- Image: `nginx:1.28.3-alpine`
- Container port: 80; no host port is published
- Network: external `app-net`
- Files: read-only bind mount from `/docker/howto/site`
- No database, application secrets, or Docker data volumes
- Health: `/healthz`
- Protected hostname: `howto.imurph.com` with no path restriction
- Access application: `How-To Pilot`
- Access policy: `Approved How-To Reviewers`, exact approved email addresses
- Login: one-time PIN; application session: one week

Manage reviewer identities only in Cloudflare; do not store the email allowlist
in Git. Access must remain enabled for the entire hostname, including MP4s,
posters, the catalog, and health endpoint. Origin sends private/no-store headers.

## Update

Back up the current remote configuration and site before replacing files:

```sh
ssh hostinger-vps 'cp -a /docker/howto /docker/howto.backup-$(date +%Y%m%d-%H%M%S)'
```

From the presentation project:

```sh
rsync -az --exclude .DS_Store presentation/index.html presentation/catalog.js presentation/catalog.csv presentation/videos presentation/posters hostinger-vps:/docker/howto/site/
```

From the infrastructure repository:

```sh
scp docker/howto/docker-compose.yml docker/howto/default.conf hostinger-vps:/docker/howto/
ssh hostinger-vps 'cd /docker/howto && docker compose config --quiet && docker compose pull && docker compose run --rm --no-deps howto nginx -t && docker compose up -d'
```

No server restart is needed for asset-only changes. Site assets are intentionally
excluded from this infrastructure repository. Preserve the local presentation
for offline use at the meeting.

## Verify and roll back

Check `docker compose ps`, recent logs, and `/healthz` within the container.
Unauthenticated HTTPS requests to the gallery and MP4 paths must redirect to
Cloudflare Access. In an approved browser session, confirm gallery navigation,
video playback, seeking, and catalog download.

For a failed update, restore configuration and assets from the dated backup and
run `docker compose up -d`. Do not remove volumes or change other services. To
take this new site offline, run `docker compose stop` in `/docker/howto`; retain
Cloudflare Access and all files.
