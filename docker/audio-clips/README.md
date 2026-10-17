# Audio Clips deployment

Target: https://clips.imurph.com. Application source: `/Users/mikemurphy/Code/Projects/audio-shorts` (product name: Audio Clips).

This stack follows the Stylelock/Podcast Asset Finder pattern: Cloudflare Access → proxied DNS → Traefik → app-net. It publishes no host ports. Cloudflare handles sign-in only; the VPS stores and processes files and calls OpenAI.

## Runtime

- Remote directory: `/docker/audio-clips`; sanitized source in `app/`.
- Image: `audio-clips:0.2.1`; non-root UID 10001, read-only root filesystem.
- Streamlit port: 8517. Internal forward-auth validator: 8518.
- Persistent named volume: `audio-clips_audio_clips_data`, mounted at `/storage`.
- Verified email addresses map to separate hashed workspace directories.
- App limit: 2 GB RAM / 1.5 CPUs. Auth limit: 128 MB RAM / 0.25 CPUs.
- 90 MB upload cap, two-hour episode cap, 1 GB per tester, 5 GB total application storage.
- Single analysis worker, at most six active/queued jobs, one pending job per tester.
- Completed transcripts survive restarts; interrupted analyses can be resumed by clicking Find my clips.
- Inactive workspaces are removed after seven days. Download wanted files first.

## Access

Use a dedicated **Audio Clips Testers** allow policy with exact-email rules. The initial tester is the single address authorized by the owner in the deployment request. Do not attach the other apps' shared multi-user policy or edit those apps.

The entire hostname is protected, with no path exceptions or bypass rules. Traefik forward-auth validates the Cloudflare JWT signature, audience, issuer, expiry, and email on every request, including media and upload routes. The app separately validates the WebSocket session token before selecting a workspace.

To add testers later: Cloudflare One → Access controls → Policies → Audio Clips Testers → add exact email entries under Include → Emails. No application deployment is required.

## Setup

Copy sanitized source into `app/`, excluding `.env.local`, `.venv`, original local `media/`, development caches, and previous exports. `.dockerignore` explicitly allows only required application files into the image.

Keep the live `.env` at `/docker/audio-clips/.env` with mode 600. Configure the new application's audience, the existing Access team domain, and the authorized Shorts API key. The auth sidecar receives no OpenAI key.

From `/docker/audio-clips` on the VPS:

```sh
docker compose config --quiet
docker compose build audio-clips
docker compose up -d
docker compose ps
```

The source image is built locally on the VPS; there is no floating application image to pull. Both services use the same built image.

## Verification

Check the container health endpoints, then check the actual HTTPS hostname. Signed-out requests to `/`, `/_stcore/stream`, `/_stcore/upload_file/`, and `/media/` must redirect to Cloudflare Access. Requests without a valid JWT to the auth validator must return 403. Sign in as the initial tester and verify upload, analysis, clip playback, and download.

Run `uv run pytest -q` in the application checkout for pipeline, workspace, queue, and signed-token tests.

## Updates and rollback

Before updates, copy the current Compose file, sanitized source, and image tag to dated backups. Back up the persistent volume separately; it contains user uploads, transcripts, exports, and reviews. Keep the remote `.env` private and preserve it across updates.

To roll back, restore the previous source/Compose and image, then use `docker compose up -d --no-build`. Never use `down -v`, prune other services, or remove the persistent volume during an update.

The app is for a small trusted tester group, not public multi-tenant SaaS. Analysis jobs are queued in memory; job status and results are persisted. Server restarts mark unfinished jobs interrupted rather than charging for automatic retries.

## Deployment status — September 14, 2026

Cloudflare DNS already points the proxied hostname to the VPS. The new Access application and dedicated tester policy are saved and verified; only `mike@liquidstudios.ai` is included. HTTPOnly is enabled. Other applications and policies were not changed.

- Access application ID: `af579fd4-8706-472d-b8ea-c4e566444f9f`
- Tester policy ID: `9fdc598d-1653-40f1-b82e-61e06faee6a0`
- Team domain: `https://mikemurphy.cloudflareaccess.com`
- Audience: see `.env.example` (public identifier, not a secret).

Deployed at **https://clips.imurph.com**. Both containers are healthy. Capacity before deployment: approximately 4.6 GB available RAM and 41 GB free disk. The private server `.env` contains the authorized Shorts API key. The owner workspace includes the original example episode and its four cached suggestions; new testers start empty.

Local validation: 15 automated tests pass; Linux amd64 image builds; read-only/non-root container starts with healthy Streamlit and writable persistent storage; storage survives restart. Hosted UI rejects missing authentication and opens a workspace for a mocked verified identity. The forward-auth HTTP service returns 403 without a JWT. Signed-out requests to all four listed public routes redirect to Cloudflare Access. The real HTTPS app opens as the authorized owner and displays all four suggestions. Browser playback works, all four MP3s were exported and probed on the VPS, and the server API key can access GPT-5.4. The download button was exercised, but browser download-history restrictions prevented confirming the downloaded file. A fresh browser upload and paid analysis remain for tester acceptance; the pipeline has already been exercised locally.

## Download format correction — v0.2.1

All generated clips are MP3 (`audio/mpeg`). Preview players now declare the correct MIME type; earlier previews defaulted to WAV, so the browser player menu could save MP3 bytes with a `.wav` extension. Use **Download MP3** for a short numbered title, or the ZIP button for the same readable clip names. The native player save menu may use an internal filename. Existing audio and review data are preserved. Files previously saved through a mislabeled preview can be downloaded again using the corrected button.
