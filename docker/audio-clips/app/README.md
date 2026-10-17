# Audio Clips

Find coherent excerpts in a long audio recording, review the cuts, and export the original audio as individual MP3s for an audio-to-video workflow.

This prototype runs locally or as a private VPS app. AI proposes excerpts; the listener decides whether they are useful. It does not generate voices or videos.

## Already set up on this Mac

From Terminal:

```bash
cd /Users/mikemurphy/Code/Projects/audio-shorts
uv run streamlit run app.py
```

Open **http://127.0.0.1:8517**. Keep Terminal running; press **Control-C** to stop the app. You can also double-click `Start Audio Shorts.command` in Finder.

The supplied `media/Tourist Trap.mp3` is approximately 28 minutes, 54 seconds. Saved analysis loads automatically after its first successful run.

## What to do

1. Choose a file in `media/`, or upload audio using the sidebar.
2. Choose a duration range, suggestion count, and purpose. The default is five 30–90-second promos with major spoilers avoided.
3. Click **Find my clips**. The first run transcribes the recording and makes two to four editorial model calls, including one refinement pass when needed. Subsequent analysis reuses the transcript.
4. Listen to each exact clip preview. Expand **Adjust the cut** to move its boundaries. Times are seconds into the original episode.
5. Mark each suggestion **Keep**, **Needs adjustment**, or **Pass**, and optionally leave a note.
6. Download individual MP3s, or download a ZIP containing kept clips and their review notes. Upload those MP3s to your existing video tool.

Changing sidebar settings does not regenerate anything until **Find my clips** is clicked. Reviews and boundary edits are saved in your workspace. A new analysis replaces the current suggestions; previous review JSON files and exported MP3s remain on disk.

## Setup on another Mac

Start with a copy of this project, excluding its private `.env.local` file. Requirements:

- macOS (the tested platform).
- Python 3.11 or newer; `uv` can manage the project interpreter.
- [uv](https://docs.astral.sh/uv/getting-started/installation/).
- FFmpeg and FFprobe. With Homebrew already installed: `brew install ffmpeg`.
- An OpenAI API key with API billing and access to `whisper-1` and `gpt-5.4`.

In Terminal, change into the copied `audio-shorts` directory, then run:

```bash
uv sync --locked
cp .env.example .env.local
chmod 600 .env.local
```

Set `OPENAI_API_KEY` in `.env.local` using a trusted local editor or password-manager workflow. Do not put the key in source code or chat. `SHORTS_MODEL` optionally selects another model supporting Responses structured outputs; the default is `gpt-5.4`.

`uv sync` installs dependencies into the project's `.venv`; no manual environment creation or activation is needed. `.env.local`, input media, analysis, and exports are excluded by `.gitignore`.

Verify installation, then start:

```bash
ffmpeg -version
uv run pytest -q
uv run streamlit run app.py
```

Tests should pass and the app should be available at **http://127.0.0.1:8517**. Tests do not call OpenAI.

## Private VPS testing

Private tester app: **https://clips.imurph.com** (deployed September 14, 2026). The Docker Compose package and operator instructions are in `../vps-infrastructure/docker/audio-clips/`. Cloudflare Access handles email sign-in; the VPS handles audio storage, processing, and OpenAI requests.

Hosted mode provides separate workspaces for verified tester emails, persistent storage across container restarts, and background analysis that continues when the browser closes. Uploads are limited to **90 MB and two hours**, with **1 GB per tester and 5 GB total**. Workspaces expire after **seven days without activity**; download wanted clips before then. The sidebar can remove an episode and its saved results.

The API key stays in the server's private `.env`. Source packages and Docker images exclude credentials and local recordings. This is intended for a small trusted testing group. A running job's status is saved, but the queue itself does not survive a server restart.

To refresh the sanitized VPS build context:

```bash
python3 scripts/package-vps.py
```

Packaging does not deploy or copy your API key. See the infrastructure runbook for live deployment status and verification.

## Command line

From the project root:

```bash
uv run python shorts.py "media/Tourist Trap.mp3" --export
```

This generates suggestions and exports every candidate, regardless of human review. For a different editorial direction:

```bash
uv run python shorts.py "media/Tourist Trap.mp3" --count 5 --min 45 --max 120 --brief "Suspenseful moments with a clear setup"
```

`--transcribe-only` prepares and caches the transcript without selecting clips. `--mode` changes the editorial purpose. Use `--help` for all arguments.

## How it works

1. Hash the source file to identify its cache.
2. Make a mono, 16 kHz, 64 kb/s copy for transcription. Files longer than 40 minutes are transcribed in overlapping parts, merged using word midpoint ownership.
3. Use Whisper's punctuated segment text and word timestamps to build indexed transcript rows. Adjacent fragments are combined until a sentence ends. Zero-duration word entries are retained; they are approximate alignments, not missing words.
4. Give the full transcript to an editorial model, requesting contiguous excerpts by inclusive transcript-row IDs. Each starting row includes a list of ending IDs that meet the duration range. The model cannot invent export timestamps or rewrite the source audio.
5. For a slightly short candidate, try adding complete sentences (at most 20 extra seconds) before review. Reject invalid IDs, incomplete sentence endings, remaining out-of-range durations, and overlaps. A second model call checks the exact excerpt against nearby context and the editorial purpose; excerpts it identifies as advertising are excluded. If needed, one bounded refinement pass preserves strong suggestions and seeks better alternatives, then reviews the replacements.
6. Add small boundary padding within gaps between transcribed words. FFmpeg decodes and re-encodes the original recording as 192 kb/s MP3, preserving its channel count and sample rate. Optional 15/25 ms fades soften the edges.

The UI previews the actual exported file, so playback and download use the same cut.

## Files and privacy

| Location | Contents |
| --- | --- |
| `.env.local` | Local API credential, excluded from Git |
| `media/` | Original and uploaded recordings |
| `data/<audio-hash>/` | Transcript, suggestions, token usage, and human review JSON |
| `exports/<audio-hash>/` | MP3 clips and manifests |
| `shorts.py` | Reusable processing pipeline and CLI |
| `app.py` | Streamlit review interface |
| `hosting.py` | Tester workspaces, queue, quotas, and retention |
| `access_auth.py` | Cloudflare Access token validation |
| `Dockerfile` | Linux container with Python and FFmpeg |

Local mode binds to `127.0.0.1`. Hosted mode runs behind Traefik and Cloudflare Access. Transcription audio and transcript analysis are sent to OpenAI using your API account. Text Responses calls use `store=False`; this does not mean zero provider retention. [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).

Opening saved results, reviewing clips, and exporting MP3s make no new AI requests. Clicking **Find my clips** incurs API usage. Token usage for selection and review is recorded in `suggestions.json`; this prototype does not calculate dollar charges.

## Success criteria and limitations

For the first episode, aim to find **at least three useful clips out of five suggestions**, with only minor boundary edits. The UI records the human decision; AI's “Strong candidate” label is not a success measurement.

- Word timestamps and punctuation are approximate. Always listen to the first and last words.
- Background music, effects, and overlapping speech can make clean audio cuts harder. The prototype uses word gaps, not music-aware editing or forced alignment.
- A complete sentence may still need outside context. The second editorial pass helps flag this but cannot guarantee quality or spoiler avoidance.
- Fewer clips may be returned if suggestions fail validation; the app reports this rather than filling slots with arbitrary cuts.
- MP3 export re-encodes the source; it is not a lossless operation.
- Hosted mode queues analysis through one worker, with at most six pending jobs and one per tester. Interrupted jobs require a manual retry after a server restart. There is no cancellation control.
- Very long episodes can exceed model context limits even though transcription is chunked. Multi-part transcript stitching is implemented but not validated on the supplied single-part episode.

## Troubleshooting

- **API usage/rate limit:** check the Shorts project's billing and limits, wait if appropriate, then retry. Completed transcript parts are cached.
- **No transcript or inaccurate words:** check that the recording contains clear speech. For a fresh transcription, remove that episode's `data/<audio-hash>/` folder after backing up any desired reviews.
- **Port already in use:** open the existing app at `127.0.0.1:8517`, or stop its Terminal process before restarting.
- **FFmpeg missing:** install FFmpeg, then restart the app from a Terminal where `ffmpeg -version` works.

## Updates and removal

After replacing source files with a newer project version, stop the app and run `uv sync --locked`, then restart it. Preserve `media/`, `data/`, `exports/`, and `.env.local` if you want to keep your work.

To remove the prototype, stop it and delete this project directory after copying any MP3s or source media you want to keep. Its dependencies live in `.venv`; it does not install a background service. Revoke the Shorts API key separately if it is no longer needed.

## Engineer handoff

Run `uv run pytest -q` for boundary validation and real MP3 export tests. The application can also be exercised with Streamlit's `AppTest` without paid API calls when cached suggestions exist.

Production work should focus on human-rated clip quality across multiple episodes, acoustic boundary refinement, retries and job progress, media storage, authentication, and cost controls. The two prompts, typed response schemas, and local JSON artifacts provide a starting contract for integrating into the existing video pipeline.

API references: [timestamped transcription](https://developers.openai.com/api/docs/guides/speech-to-text) and [structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs).

## Download format correction — v0.2.1

All generated clips are MP3 (`audio/mpeg`). Preview players now declare the correct MIME type; earlier previews defaulted to WAV, so the browser player menu could save MP3 bytes with a `.wav` extension. Use **Download MP3** for a short numbered title, or the ZIP button for the same readable clip names. The native player save menu may use an internal filename. Existing audio and review data are preserved. Files previously saved through a mislabeled preview can be downloaded again using the corrected button.
