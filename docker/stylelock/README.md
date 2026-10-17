# Stylelock deployment

Status (2026-09-26): version 0.3.0 is live at https://stylelock.imurph.com with personal style libraries. The image built on the VPS and all 25 tests passed inside it. Signed-in My Library and signed-out Access protection were verified. No paid generation was needed for this update. The prior release had a successful real OpenAI generation.

- Hostname: https://stylelock.imurph.com
- Source: `/Users/mikemurphy/Code/Projects/style-lock`
- Remote service directory: `/docker/stylelock`
- Remote build context: `/docker/stylelock/app`
- Image: `stylelock:0.3.0` (application commit `10c1bbf`)
- Container port: `8787`; no published host ports
- Network: `app-net`; Traefik `websecure` with `mytlschallenge`
- Identity: Cloudflare Access with origin JWT validation
- Provider: OpenAI, `gpt-4.1`
- Storage: `stylelock_stylelock-data` mounted at `/app/data`; SQLite schema 1 in `/app/data/stylelock.sqlite3`; bounded temporary tmpfs

Keep the real `.env` on the VPS with mode 600. Do not copy API credentials into this repository. Manage approved teammate identities in Cloudflare.

Copy reviewed application files into `/docker/stylelock/app`, excluding `.env`, development environments, screenshots, and caches. Copy this Compose definition to `/docker/stylelock/docker-compose.yml`. Configure the Access audience and OpenAI key in the service environment before starting.

From `/docker/stylelock` on the VPS:

```sh
docker compose config --quiet
docker compose build
docker compose up -d
docker compose ps
```

Verify container health, unauthenticated Access redirects, and a signed-in generation through the public hostname. Before subsequent updates, back up the existing Compose/configuration and retain the previous source and image for rollback. Do not remove unrelated services or volumes.

## Access configuration verified

- Application ID: `82c936d1-dfda-41b2-bc60-9bd7e33d4b37`
- Existing reusable policy: Approved Podcast Asset Users (nine approved identities)
- Login: email one-time PIN; session: one week
- Audience: recorded in `.env.example`; this is a public identifier, not a credential
- Signed-out requests to `/`, `/api/config`, `/api/analyze`, and `/static/app.js` redirect to the Cloudflare Access login.

The user explicitly confirmed reuse of all nine policy members. No other application's policy was changed.

## Teammate testing

Share https://stylelock.imurph.com with users already approved by the reusable Access policy. Test the generated descriptions in The Studio and compare resulting B-roll against the references. End-to-end text generation is verified; downstream video quality remains a creative evaluation.

The initial live test returned exhausted-credit errors. Funding the same API organization resolved it without a key change or service restart. Version 0.2.1 now distinguishes exhausted credits from transient rate limits.

## Verification and rollback

- The 0.2.0 image passed all 18 original tests on the VPS.
- The quota error fix adds a nineteenth regression test; all 19 passed locally and inside the 0.2.1 Docker image on the VPS.
- The application has a read-only root filesystem, runs as UID 10001, and publishes no host port.
- Original deployment backups: `/docker/stylelock/docker-compose.yml.pre-0.2.1` and `/docker/stylelock/app.py.pre-0.2.1`.
- The `stylelock:0.2.0` image is retained for rollback.

For rollback, restore the saved Compose definition and `app.py`, then run `docker compose up -d --no-build` in `/docker/stylelock`. Restore the corresponding tracked/source files locally too. Preserve the existing private `.env`.


## Personal library release: 2026-09-26

The active `/docker/stylelock/app` symlink points to `releases/10c1bbf`, exported from the private application repository. The former source is retained in `app.pre-library-20260926`. Runtime `.env` was preserved byte-for-byte. Each verified Cloudflare identity owns a private collection; existing pre-library browser results are not automatically imported.

Current rollback artifacts:

- `/var/backups/stylelock/pre-library-20260926.tar.gz` contains the previous source, Compose file, README, and private configuration. Keep it private on the VPS.
- `/var/backups/stylelock/docker-compose.pre-library.yml` is the old standalone deployment definition.
- `stylelock:0.2.1` and `stylelock:rollback-pre-library-20260926` retain the old image.

To roll back the application, copy the saved Compose file back to `/docker/stylelock/docker-compose.yml`, then run `docker compose up -d --no-build --wait`. Do not remove `stylelock_stylelock-data`: the old app cannot browse the library, but retaining this volume allows reapplying 0.3.0 without deleting collections. Restore the old build-context directory too before any subsequent rebuild. Pause the new backup cron during a rollback to the old image, which has no library helper.

## Library backups

`backup_stylelock.sh` runs SQLite's consistent online backup helper inside the container, streams the result from its tmpfs to `/var/backups/stylelock`, restricts the local file to mode 600, and copies it to `vault-nas:/Vault/Backups/Hostinger VPS/stylelock`. Streaming is intentional: Docker copy did not expose the tmpfs file on this host. No secrets or personal library contents are copied to the local source repository.

`backup.cron` is installed as `/etc/cron.d/stylelock-backup`: daily at 03:25 UTC (the server timezone). Output goes to `/var/backups/stylelock/backup.log`. Failures return nonzero; there is currently no dedicated Kuma backup monitor. Local and NAS backup retention is manual pending a team policy; monitor disk usage.

For a manual backup:

```sh
ssh hostinger-vps /docker/stylelock/backup_stylelock.sh
```

For restore/SSO migration guidance, see the application's `docs/engineering-handoff.md`. Restore with the app stopped and retain its internal users and identity mappings. A volume is not an offsite backup.

### Backup verification on 2026-09-26

The first local SQLite backup passed `PRAGMA integrity_check` and contained schema version 1. The offsite copy could not complete: the existing NAS SFTP endpoint over Tailscale timed out. No NAS or Tailscale configuration was changed. The nightly job retains its local backup before trying the NAS; offsite copies remain unverified until connectivity is restored. The copy has a two-minute outer timeout and reports failure rather than claiming an offsite backup succeeded.
