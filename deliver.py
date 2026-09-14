#!/usr/bin/env python3
"""Deliver rendered reels: presigned R2 link + thumbnail -> Trello 'Proof ready' card +
summary email. Runs inside the render worker container after rendering, so the whole
render->proof loop is self-contained (no laptop). Uses only stdlib + rclone (already present).

Input: argv[1] = manifest json, a list of {"key","local","remote"} for each rendered reel.
Reads /app/reels_meta.json for per-key {title, hook, why_viral, spoken_gist} (optional).
Env: R2_BUCKET, R2_* (for rclone), TRELLO_KEY, TRELLO_TOKEN, HELM_PROOF_LIST,
     GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET, GMAIL_REFRESH_TOKEN, EMAIL_TO.
"""
import json, os, subprocess, sys, base64, urllib.request, urllib.parse
from pathlib import Path

BUCKET = os.environ["R2_BUCKET"]
META = {}
mp = Path("/app/reels_meta.json")
if mp.exists():
    try: META = json.loads(mp.read_text())
    except Exception: META = {}

def _r2env():
    e = dict(os.environ)
    e.update({
        "RCLONE_CONFIG_MCCR2_TYPE": "s3", "RCLONE_CONFIG_MCCR2_PROVIDER": "Cloudflare",
        "RCLONE_CONFIG_MCCR2_ACCESS_KEY_ID": os.environ["R2_ACCESS_KEY_ID"],
        "RCLONE_CONFIG_MCCR2_SECRET_ACCESS_KEY": os.environ["R2_SECRET_ACCESS_KEY"],
        "RCLONE_CONFIG_MCCR2_ENDPOINT": os.environ["R2_ENDPOINT"], "RCLONE_CONFIG_MCCR2_REGION": "auto",
    })
    return e

def presign(remote_path, hours=168):  # 168h = 7d, the SigV4 presign max
    r = subprocess.run(["rclone", "link", "--expire", f"{hours}h",
                        f"mccr2:{BUCKET}/{remote_path}", "--s3-no-check-bucket"],
                       env=_r2env(), capture_output=True, text=True)
    return (r.stdout or "").strip()

def make_thumb(local_mp4, key):
    out = f"/tmp/{key}.jpg"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "1.2", "-i", local_mp4,
                    "-frames:v", "1", "-q:v", "3", out], check=False)
    if not Path(out).exists():
        return None
    remote = f"_cloud_renders/thumbs/{key}.jpg"
    subprocess.run(["rclone", "copy", out, f"mccr2:{BUCKET}/_cloud_renders/thumbs/",
                    "--s3-no-check-bucket"], env=_r2env(), check=False)
    return presign(remote)

def trello_post(path, params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request("https://api.trello.com/1" + path, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def make_card(title, desc, cover_url):
    card = trello_post("/cards", {
        "key": os.environ["TRELLO_KEY"], "token": os.environ["TRELLO_TOKEN"],
        "idList": os.environ["HELM_PROOF_LIST"], "name": title, "desc": desc,
        "pos": "top",
    })
    cid = card["id"]
    if cover_url:
        try:
            trello_post(f"/cards/{cid}/attachments", {
                "key": os.environ["TRELLO_KEY"], "token": os.environ["TRELLO_TOKEN"],
                "url": cover_url, "setCover": "true"})
        except Exception as e:
            print("cover attach failed:", e)
    return card.get("shortUrl") or card.get("url")

def gmail_send(subject, body):
    cid = os.environ.get("GMAIL_CLIENT_ID"); sec = os.environ.get("GMAIL_CLIENT_SECRET")
    rt = os.environ.get("GMAIL_REFRESH_TOKEN"); to = os.environ.get("EMAIL_TO", "tim@atj.digital")
    if not (cid and sec and rt):
        print("gmail env missing; skipping email"); return False
    tok = urllib.request.urlopen(urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode({"client_id": cid, "client_secret": sec,
            "refresh_token": rt, "grant_type": "refresh_token"}).encode(), method="POST"), timeout=30)
    at = json.loads(tok.read().decode())["access_token"]
    msg = f"To: {to}\r\nSubject: {subject}\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n{body}"
    raw = base64.urlsafe_b64encode(msg.encode()).decode()
    req = urllib.request.Request("https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
        data=json.dumps({"raw": raw}).encode(),
        headers={"Authorization": f"Bearer {at}", "Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=30)
    return True

def main():
    # manifest lines: KEY|LOCAL_PATH|REMOTE_PATH
    items = []
    for ln in Path(sys.argv[1]).read_text().splitlines():
        ln = ln.strip()
        if not ln:
            continue
        parts = ln.split("|")
        items.append({"key": parts[0],
                      "local": parts[1] if len(parts) > 1 else None,
                      "remote": parts[2] if len(parts) > 2 else None})
    lines = ["The cloud render worker finished a batch of short social reels. Each is on the",
             "Helm Ops board 'Proof ready' list for you to proof, and the video links are below",
             "(they stream in a browser, valid ~7 days).", ""]
    for it in items:
        key = it["key"]; local = it.get("local"); remote = it.get("remote")
        m = META.get(key, {})
        title = m.get("title", key)
        video_url = presign(remote) if remote else ""
        cover = make_thumb(local, key) if local else None
        desc = "\n".join(filter(None, [
            f"HOOK: {m.get('hook','')}" if m.get("hook") else "",
            f"Says: {m.get('spoken_gist','')}" if m.get("spoken_gist") else "",
            f"Why it can travel: {m.get('why_viral','')}" if m.get("why_viral") else "",
            "", f"Watch (7 day link): {video_url}",
            f"Reel key: {key}", "", "First draft, cloud rendered. Proof and tell me keep / kill / fix."]))
        try:
            url = make_card(f"PROOF: {title}", desc, cover)
            print(f"CARD {key}: {url}")
            lines.append(f"- {title}\n  {video_url}")
        except Exception as e:
            print(f"CARD FAILED {key}: {e}")
            lines.append(f"- {title} (card post failed): {video_url}")
    try:
        gmail_send(f"{len(items)} new cloud reels on the Helm board (Proof ready)", "\n".join(lines))
        print("summary email sent")
    except Exception as e:
        print("email failed:", e)

if __name__ == "__main__":
    main()
