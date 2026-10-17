import json
import os
import threading
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from access_auth import validate_access_token
from hosting import Jobs, RETENTION, save_upload, touch_workspace, workspace_for


def test_workspace_identity_cannot_escape_storage(tmp_path):
    assert workspace_for('Mike@example.com',tmp_path)==workspace_for(' mike@example.com ',tmp_path)
    assert workspace_for('other@example.com',tmp_path)!=workspace_for('mike@example.com',tmp_path)
    assert workspace_for('../../someone@example.com',tmp_path).parent==tmp_path/'users'


def test_access_signature_audience_expiry_and_email():
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    now=int(time.time())
    claims={'sub':'tester','email':'Mike@example.com','aud':['clips-audience'],'iss':'https://team.cloudflareaccess.com','iat':now,'exp':now+60}
    def check(payload, signing=key):
        token=jwt.encode(payload,signing,algorithm='RS256')
        return validate_access_token(token,domain=claims['iss'],audience='clips-audience',signing_key=key.public_key())
    assert check(claims)=='mike@example.com'
    for altered in ({**claims,'aud':['other-app']},{**claims,'exp':now-60},{k:v for k,v in claims.items() if k!='email'}):
        with pytest.raises(jwt.PyJWTError): check(altered)
    with pytest.raises(jwt.InvalidSignatureError):
        check(claims,rsa.generate_private_key(public_exponent=65537,key_size=2048))
    with pytest.raises(ValueError): validate_access_token('',domain=claims['iss'],audience='clips-audience')


def test_reject_fake_audio_and_oversize(tmp_path,monkeypatch):
    import hosting
    monkeypatch.setattr(hosting,'UPLOAD_LIMIT',10)
    workspace=workspace_for('test@example.com',tmp_path)
    with pytest.raises(ValueError,match='90 MB'): save_upload(workspace,'file.mp3',b'x'*11,tmp_path)
    with pytest.raises(Exception): save_upload(workspace,'file.mp3',b'fake',tmp_path)
    assert not list(workspace.rglob('*.mp3'))


def test_single_worker_deduplicates_and_retention_skips_pending(tmp_path):
    first=workspace_for('first@example.com',tmp_path)
    second=workspace_for('second@example.com',tmp_path)
    expired=workspace_for('expired@example.com',tmp_path)
    for w in (first,second,expired): touch_workspace(w)
    now=time.time()
    for w in (first,expired): os.utime(w/'.last-used',(now-RETENTION-10,)*2)
    source=tmp_path/'input.mp3'; source.write_bytes(b'test')
    started=threading.Event(); release=threading.Event(); active=[]
    def runner(workspace,source,settings,progress):
        active.append(workspace)
        assert len(active)==1
        started.set(); release.wait(5)
        active.pop()
    jobs=Jobs(tmp_path,runner=runner)
    identity=jobs.submit(first,source,{})
    assert started.wait(2)
    jobs.submit(second,source,{})
    with pytest.raises(ValueError,match='already'): jobs.submit(first,source,{})
    jobs.cleanup(now+1)
    assert first.exists() and second.exists() and not expired.exists()
    release.set(); jobs.executor.shutdown(wait=True)
    assert jobs.status(first,identity)['state']=='complete'
    assert jobs.status(second,identity)['state']=='complete'


def test_restart_reports_interrupted_job(tmp_path):
    w=workspace_for('user@example.com',tmp_path)
    p=w/'data'/'test'/'job.json'; p.parent.mkdir(parents=True)
    p.write_text(json.dumps({'state':'running','message':'old job'}))
    jobs=Jobs(tmp_path)
    assert jobs.status(w,'test')['state']=='interrupted'
    jobs.executor.shutdown()
