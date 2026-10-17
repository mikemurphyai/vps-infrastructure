"""Private tester workspaces, bounded single-worker analysis, and temporary storage."""
import hashlib
import json
import os
import re
import shutil
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from shorts import ROOT, analyze, asset_id, probe, save_json, transcribe

HOSTED = os.environ.get("AUTH_MODE", "local") == "cloudflare"
STORAGE = Path(os.environ.get("CLIPS_STORAGE", str(ROOT / "hosted-data"))).resolve()
UPLOAD_LIMIT = 90 * 1024 * 1024
TOTAL_LIMIT = int(os.environ.get("CLIPS_STORAGE_GB", "5")) * 1024**3
USER_LIMIT = int(os.environ.get("CLIPS_USER_STORAGE_GB", "1")) * 1024**3
RETENTION = int(os.environ.get("CLIPS_RETENTION_DAYS", "7")) * 86400
storage_lock = threading.RLock()


def workspace_for(email, storage=STORAGE):
    identity = hashlib.sha256(email.strip().lower().encode()).hexdigest()
    return storage / "users" / identity


def byte_size(folder):
    return sum(p.stat().st_size for p in folder.rglob("*") if p.is_file() and not p.is_symlink()) if folder.exists() else 0


def check_capacity(workspace, additional=0, storage=STORAGE):
    if byte_size(workspace)+additional > USER_LIMIT:
        raise ValueError("Your temporary workspace is full. Remove an older episode before uploading or exporting more audio.")
    if byte_size(storage)+additional > TOTAL_LIMIT:
        raise ValueError("The prototype's temporary storage is full. Try again after older workspaces expire.")
    storage.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(storage).free < additional + 512*1024*1024:
        raise ValueError("The server is low on free space. Please try again later.")


def touch_workspace(workspace):
    workspace.mkdir(parents=True,exist_ok=True)
    (workspace/".last-used").touch()


def save_upload(workspace, name, contents, storage=STORAGE):
    if len(contents)>UPLOAD_LIMIT:
        raise ValueError("Upload an audio file no larger than 90 MB. MP3 is recommended.")
    extension = Path(name).suffix.lower()
    if extension not in {".mp3",".wav",".m4a",".flac",".ogg",".aac"}:
        raise ValueError("Unsupported audio format.")
    safe_name = re.sub(r"[^\w. -]", "_", Path(name).name)[:140]
    target = workspace/"media"/f"{hashlib.sha256(contents).hexdigest()[:12]}-{safe_name}"
    with storage_lock:
        if target.exists():
            return target
        check_capacity(workspace,len(contents),storage)
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(contents)
        try:
            info=probe(target)
            if info["duration"]>7200:
                raise ValueError("For this prototype, upload an episode up to two hours long.")
        except Exception:
            target.unlink(missing_ok=True)
            raise
        touch_workspace(workspace)
    return target


def safe_failure(error):
    name=type(error).__name__
    if name=="RateLimitError":
        return "OpenAI reported a usage or rate limit. Check API billing or retry later."
    if name=="AuthenticationError":
        return "The server's OpenAI key was rejected. Please contact the app owner."
    if name in ("APIConnectionError","APITimeoutError"):
        return "The OpenAI connection timed out. Completed transcript work is saved; retry shortly."
    if isinstance(error,ValueError):
        return str(error)
    return f"Analysis could not finish ({name}). Completed transcript work is saved. Please retry."


class Jobs:
    def __init__(self, storage=STORAGE, runner=None):
        self.storage=storage
        self.executor=ThreadPoolExecutor(max_workers=1,thread_name_prefix="audio-clips")
        self.lock=threading.RLock()
        self.pending={}
        self.runner=runner or self._analyze
        self.last_cleanup=0
        self.maintenance_started=False

    def start_maintenance(self):
        with self.lock:
            if self.maintenance_started: return
            self.maintenance_started=True
        def maintain():
            while True:
                try:
                    self.cleanup()
                except OSError:
                    pass  # A later sweep retries; do not log private paths or user data.
                threading.Event().wait(3600)
        threading.Thread(target=maintain,name="audio-clips-cleanup",daemon=True).start()

    def _analyze(self, workspace, source, settings, progress):
        transcript=transcribe(source, progress=progress, data_dir=workspace/"data")
        return analyze(transcript, **settings, progress=progress, data_dir=workspace/"data")

    def status(self,workspace,identity):
        path=workspace/"data"/identity/"job.json"
        if not path.exists(): return None
        value=json.loads(path.read_text())
        with self.lock:
            if value["state"] in ("queued","running") and str(workspace) not in self.pending:
                value.update(state="interrupted",message="The server restarted before this job finished. Click Find my clips to resume with saved transcript work.")
                save_json(path,value)
        return value

    def submit(self,workspace,source,settings):
        identity=asset_id(source)
        key=str(workspace)
        with self.lock:
            if key in self.pending:
                raise ValueError("You already have an analysis queued or running. Wait for it to finish before starting another.")
            if len(self.pending)>=6:
                raise ValueError("The analysis queue is full. Please try again shortly.")
            with storage_lock:
                check_capacity(workspace,25*1024*1024,self.storage)
                touch_workspace(workspace)
            status_path=workspace/"data"/identity/"job.json"
            save_json(status_path,{"state":"queued","message":"Queued. Episodes are processed one at a time.","updated":time.time()})
            self.pending[key]=identity
            self.executor.submit(self._run,workspace,source,settings,status_path)
        return identity

    def _run(self,workspace,source,settings,status_path):
        def progress(message):
            save_json(status_path,{"state":"running","message":message,"updated":time.time()})
        try:
            progress("Starting analysis…")
            self.runner(workspace,source,settings,progress)
            save_json(status_path,{"state":"complete","message":"Your clip suggestions are ready.","updated":time.time()})
        except Exception as error:
            save_json(status_path,{"state":"error","message":safe_failure(error),"updated":time.time()})
        finally:
            with self.lock:
                self.pending.pop(str(workspace),None)
                touch_workspace(workspace)

    def cleanup(self,now=None):
        now=time.time() if now is None else now
        with self.lock,storage_lock:
            if now-self.last_cleanup<3600: return
            self.last_cleanup=now
            users=self.storage/"users"
            if not users.exists(): return
            for workspace in users.iterdir():
                if not workspace.is_dir() or workspace.is_symlink() or str(workspace) in self.pending: continue
                stamp=workspace/".last-used"
                if stamp.exists() and now-stamp.stat().st_mtime>RETENTION:
                    shutil.rmtree(workspace)
