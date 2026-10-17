"""Local review workbench. Start with: uv run streamlit run app.py"""
import copy
import hashlib
import io
import json
import mimetypes
import os
import re
import shutil
import zipfile
from pathlib import Path

import streamlit as st

from shorts import DATA, EXPORTS, ROOT, VERSION, analyze, asset_id, export_clip, probe, save_json, transcribe
from access_auth import validate_access_token
from hosting import (HOSTED, Jobs, check_capacity, save_upload, storage_lock,
                     touch_workspace, workspace_for)

st.set_page_config(page_title="Audio Clips", page_icon="🎧", layout="wide")

workspace = ROOT
jobs = None
if HOSTED:
    try:
        email = validate_access_token(st.context.headers.get("Cf-Access-Jwt-Assertion", ""))
    except Exception:
        st.error("Sign in through clips.imurph.com to open your workspace. If your session expired, refresh and sign in again.")
        st.stop()
    @st.cache_resource
    def job_manager():
        manager=Jobs()
        manager.start_maintenance()
        return manager
    jobs = job_manager()
    jobs.cleanup()
    workspace = workspace_for(email)
    with storage_lock:
        touch_workspace(workspace)
    DATA = workspace / "data"
    EXPORTS = workspace / "exports"
    st.sidebar.caption(f"Signed in as {email}")
    st.sidebar.caption("Your uploads and reviews are saved in your own workspace. Download files you want to keep; workspaces expire after 7 days without activity.")


def timecode(seconds):
    minutes, seconds = divmod(float(seconds), 60)
    return f"{int(minutes):02d}:{seconds:04.1f}"


def report_error(error):
    # Provider errors may contain request details; expose safe error categories only.
    name = type(error).__name__
    if name == "AuthenticationError":
        message = "The OpenAI key was rejected. Check the Shorts key in .env.local."
    elif name == "RateLimitError":
        message = "OpenAI reported a usage or rate limit. Check the Shorts project's API billing, then retry."
    elif name in ("APIConnectionError", "APITimeoutError"):
        message = "Could not finish the OpenAI request. Check your connection and retry; completed transcription is saved."
    elif isinstance(error, ValueError):
        message = str(error)
    else:
        message = f"This operation could not finish ({name}). Check that FFmpeg is installed and the file is readable, then retry."
    st.error(message)


st.markdown("### 🎧 AUDIO CLIPS")
st.title("Find the moment. Keep the story.")
st.write("Turn a full episode into coherent excerpts you can take straight to your audio-to-video tool.")

with st.sidebar:
    st.header("Your episode")
    media = workspace / "media"
    media.mkdir(parents=True,exist_ok=True)
    upload = st.file_uploader("Upload audio", type=["mp3", "wav", "m4a", "flac", "ogg", "aac"],max_upload_size=90 if HOSTED else 500,key=f"upload-{st.session_state.get('upload-version',0)}")
    uploaded_path = None
    if upload:
        contents = upload.getvalue()
        if HOSTED:
            try:
                uploaded_path=save_upload(workspace,upload.name,contents)
            except Exception as error:
                report_error(error)
                st.stop()
        else:
            short_hash = hashlib.sha256(contents).hexdigest()[:12]
            safe = re.sub(r"[^\w. -]", "_", Path(upload.name).name)
            uploaded_path = media / f"{short_hash}-{safe}"
            if not uploaded_path.exists():
                uploaded_path.write_bytes(contents)
    available = sorted(p for p in media.iterdir() if p.suffix.lower() in (".mp3", ".wav", ".m4a", ".flac", ".ogg", ".aac"))
    if not available:
        st.info("Upload an episode to begin.")
        st.stop()
    chosen = st.selectbox("Or choose a saved episode", available, format_func=lambda p:p.name,
                          index=available.index(uploaded_path) if uploaded_path in available else 0)
    st.divider()
    st.header("What makes a good clip?")
    with st.form("settings"):
        count = st.slider("Number of suggestions", 1, 10, 5)
        duration_range = st.slider("Clip length (seconds)", 10, 300, (30,90), step=5)
        mode = st.selectbox("Purpose", ["Promos / avoid spoilers", "Standalone highlights / spoilers allowed"])
        brief = st.text_area("Editorial direction (optional)", placeholder="e.g. Suspenseful moments with enough setup for a new listener",max_chars=2000)
        generate = st.form_submit_button("Find my clips", type="primary", use_container_width=True,
                                        disabled=not bool(os.environ.get("OPENAI_API_KEY")))
    st.caption("Analysis sends a compressed audio copy and its transcript to OpenAI. API charges apply. " + ("Your files are stored temporarily on the server." if HOSTED else "Original audio and exported clips stay on this Mac."))
    st.caption("Returning to saved suggestions does not make another API call.")

try:
    stat = chosen.stat()
    @st.cache_data(show_spinner=False)
    def identify(path, size, modified):
        return asset_id(Path(path)), probe(Path(path))
    identity, metadata = identify(str(chosen), stat.st_size, stat.st_mtime_ns)
except Exception as error:
    report_error(error)
    st.stop()

folder = DATA / identity
suggestions_file = folder / "suggestions.json"
transcript_file = folder / "transcript.json"

if HOSTED:
    with st.sidebar.popover("Remove this episode"):
        st.write("This removes the selected audio, its transcript, clips, and review notes from your workspace.")
        confirm_remove=st.checkbox("I have downloaded anything I want to keep.")
        if st.button("Remove episode and results",disabled=not confirm_remove):
            with jobs.lock, storage_lock:
                if str(workspace) in jobs.pending:
                    st.error("Wait for your analysis to finish before removing an episode.")
                else:
                    chosen.unlink(missing_ok=True)
                    shutil.rmtree(folder,ignore_errors=True)
                    shutil.rmtree(EXPORTS/identity,ignore_errors=True)
                    st.session_state['upload-version']=st.session_state.get('upload-version',0)+1
                    st.rerun()

if generate:
    if duration_range[0] >= duration_range[1]:
        st.error("Choose a maximum clip length greater than the minimum.")
    elif HOSTED:
        try:
            jobs.submit(workspace,chosen,{"count":count,"min_seconds":duration_range[0],"max_seconds":duration_range[1],"mode":mode,"brief":brief})
        except Exception as error:
            report_error(error)
    else:
        with st.status("Finding moments worth sharing…", expanded=True) as status:
            try:
                transcript = transcribe(chosen, progress=st.write)
                result = analyze(transcript, count, *duration_range, mode=mode, brief=brief, progress=st.write)
                status.update(label=f"{len(result['clips'])} candidates ready to review", state="complete", expanded=False)
            except Exception as error:
                status.update(label="Analysis paused", state="error")
                report_error(error)

if HOSTED:
    @st.fragment(run_every="3s")
    def job_progress():
        state=jobs.status(workspace,identity)
        if not state: return
        if state["state"] in ("queued","running"):
            st.info(state["message"] + " You can leave this page and return later.")
            st.session_state[f"waiting-{identity}"]=True
        elif state["state"] in ("error","interrupted"):
            st.error(state["message"])
        elif state["state"]=="complete" and st.session_state.pop(f"waiting-{identity}",False):
            st.rerun()
    job_progress()

col1, col2, col3 = st.columns([3,1,1])
col1.metric("SOURCE", chosen.name)
col2.metric("EPISODE LENGTH", timecode(metadata["duration"]))
col3.metric("AUDIO", f"{metadata['sample_rate']//1000} kHz · {'Stereo' if metadata['channels']==2 else 'Mono' if metadata['channels']==1 else str(metadata['channels'])+' channels'}")

if not suggestions_file.exists():
    st.info("Ready when you are. Choose your clip length and click **Find my clips**.")
    st.audio(str(chosen), format=mimetypes.guess_type(chosen.name)[0] or "application/octet-stream")
    st.stop()

result = json.loads(suggestions_file.read_text())
transcript = json.loads(transcript_file.read_text())
if result.get("version") != VERSION:
    st.info("This episode has an older analysis. Click Find my clips to update the suggestions using the saved transcript.")
    st.stop()
result["source"] = str(chosen.resolve())
revision = hashlib.sha256(suggestions_file.read_bytes()).hexdigest()[:12]
review_file = folder / f"review-{revision}.json"
saved_reviews = json.loads(review_file.read_text()) if review_file.exists() else {}
review_key = f"reviews-{identity}-{revision}"
if review_key not in st.session_state:
    st.session_state[review_key] = saved_reviews
reviews = st.session_state[review_key]

st.caption(f"Saved suggestions · {result['settings']['min_seconds']}–{result['settings']['max_seconds']} sec · {result['settings']['mode']}")
st.write(result["episode_summary"])
st.info("AI suggestions need your ears. Listen for context and clean cuts, then mark the clips you would actually use.")
if result.get("rejected"):
    st.caption(f"During analysis, {len(result['rejected'])} proposals failed validation and were discarded. The candidates below passed the timing checks.")
clips_tab, transcript_tab = st.tabs([f"Suggested clips ({len(result['clips'])})", "Full transcript"])

with transcript_tab:
    st.audio(str(chosen), format=mimetypes.guess_type(chosen.name)[0] or "application/octet-stream")
    search = st.text_input("Search the transcript")
    for sentence in transcript["sentences"]:
        if not search or search.lower() in sentence["text"].lower():
            st.write(f"**{timecode(sentence['start'])}** · {sentence['text']}")
    st.download_button("Download transcript JSON", transcript_file.read_bytes(), file_name=f"{chosen.stem}-transcript.json", mime="application/json")

current_clips = []
with clips_tab:
    for index, clip in enumerate(result["clips"]):
        key = f"{identity}-{revision}-{index}"
        saved = reviews.get(str(index), {})
        with st.container(border=True):
            left,right = st.columns([4,1])
            left.subheader(f"{index+1:02d}  {clip['title']}")
            right.caption(f"{clip['kind']} · {clip['spoiler_risk']} spoiler risk")
            st.write(clip["reason"])
            st.caption(f"AI check: {clip['review']['verdict']} — {clip['review']['note']}")
            if clip.get("context_note"):
                st.caption(f"Context: {clip['context_note']}")
            if clip.get("boundary_note"):
                st.caption(clip["boundary_note"])
            start = saved.get("start", clip["start"])
            end = saved.get("end", clip["end"])
            with st.expander("Adjust the cut"):
                st.caption("Times are seconds into the original episode. Small adjustments let you keep a breath or remove a pause.")
                a,b,c = st.columns([1,1,2])
                start = a.number_input("Start (seconds)", min_value=0., max_value=float(metadata["duration"]),
                                       value=float(start), step=.1, format="%.3f", key=f"start-{key}")
                end = b.number_input("End (seconds)", min_value=0., max_value=float(metadata["duration"]),
                                     value=float(end), step=.1, format="%.3f", key=f"end-{key}")
                fade = c.checkbox("Soften edges (15 / 25 ms)", value=saved.get("fade",True), key=f"fade-{key}")
                if st.button("Reset to suggested cut",key=f"reset-{key}"):
                    reviews[str(index)] = {**saved,"start":clip["start"],"end":clip["end"]}
                    save_json(review_file,reviews)
                    for prefix in ("start", "end"):
                        del st.session_state[f"{prefix}-{key}"]
                    st.rerun()
            if end <= start:
                st.error("The end must be after the start.")
                continue
            selected_words = [w for w in transcript["words"] if w["end"] >= start and w["start"] <= end]
            actual_text = clip["text"] if start == clip["start"] and end == clip["end"] else " ".join(w["word"] for w in selected_words)
            if any(w["start"] < start < w["end"] or w["start"] < end < w["end"] for w in selected_words):
                st.warning("This adjustment cuts through a transcribed word. Move the boundary before downloading.")
            st.caption(f"{timecode(start)} → {timecode(end)} · {end-start:.1f} seconds")
            try:
                with storage_lock:
                    capacity_check=(lambda:check_capacity(workspace,int((end-start)*24000*1.1))) if HOSTED else None
                    output = export_clip(chosen, start, end, f"{index+1:02d}-{clip['title']}", EXPORTS/identity, fade,before_write=capacity_check)
                st.audio(str(output), format="audio/mpeg")
                st.caption("MP3 preview · Use Download MP3 below for a file with a readable name.")
            except Exception as error:
                report_error(error)
                continue
            with st.expander("Read this excerpt"):
                st.write(actual_text)
            choice, download = st.columns([2,1])
            statuses = ["Not reviewed", "Keep", "Needs adjustment", "Pass"]
            decision = choice.radio("Would you use this clip?", statuses,
                                    index=statuses.index(saved.get("decision","Not reviewed")), horizontal=True, key=f"decision-{key}")
            notes = st.text_input("Your review note (optional)", value=saved.get("notes",""), key=f"notes-{key}",
                                  placeholder="e.g. Strong hook; trim the pause at the end")
            download_name = f"{index+1:02d}-{re.sub(r'[^a-z0-9]+', '-', clip['title'].lower()).strip('-')[:48].rstrip('-') or 'clip'}.mp3"
            download.download_button("Download MP3", output.read_bytes(), file_name=download_name,
                                     mime="audio/mpeg", key=f"download-{key}", use_container_width=True)
            reviews[str(index)] = {"start":start,"end":end,"fade":fade,"decision":decision,"notes":notes}
            current_clips.append({**clip, **reviews[str(index)], "text":actual_text,"duration":round(end-start,3),"file":str(output),"download_name":download_name})
    save_json(review_file,reviews)
    kept = [c for c in current_clips if c["decision"] == "Keep"]
    st.divider()
    st.subheader(f"{len(kept)} clips marked Keep")
    st.caption("Prototype target: at least 3 useful clips from this episode after only minor adjustments. Your review determines the result.")
    if kept:
        export_manifest = {**copy.deepcopy(result),"clips":kept}
        archive = io.BytesIO()
        with zipfile.ZipFile(archive,"w",compression=zipfile.ZIP_DEFLATED) as z:
            for c in kept:
                z.write(c["file"],c["download_name"])
            z.writestr("clip-manifest.json",json.dumps(export_manifest,indent=2,ensure_ascii=False))
        save_json(EXPORTS/identity/"reviewed-clips.json",export_manifest)
        st.download_button("Download kept clips + review notes (ZIP)",archive.getvalue(),file_name=f"{chosen.stem}-clips.zip",mime="application/zip",type="primary")
    else:
        st.caption("Mark a clip Keep to include it in the ZIP download. Individual MP3 downloads are available above.")
