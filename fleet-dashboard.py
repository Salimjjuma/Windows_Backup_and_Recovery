#!/usr/bin/env python3
"""Fleet backup dashboard (restic + Wasabi S3).

Runs on the IT admin machine (same one that runs check-fleet.ps1 /
test-restore.ps1). It shells out to `restic` once per laptop, so the AWS
keys and RESTIC_PASSWORD_FILE stay in the server process environment and
are never sent to the browser.

Stdlib only - no pip install needed. Python 3.8+.

Usage:
    set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / RESTIC_PASSWORD_FILE
    python fleet-dashboard.py [--host 127.0.0.1] [--port 8080]

Then open http://127.0.0.1:8080 in a browser.
"""

import argparse
import concurrent.futures
import csv
import html
import io
import json
import os
import shutil
import subprocess
import threading
import urllib.parse
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "fleet-config.json")

DEFAULTS = {
    "endpoint": "https://s3.eu-south-1.wasabisys.com",
    "bucket": "mewabackup",
    "hostnames": [],
}

JOBS = {}
JOBS_LOCK = threading.Lock()
PER_HOST_TIMEOUT = 120
MAX_WORKERS = 6


# ---------------------------------------------------------------- config

def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            saved = json.load(f)
        for k in DEFAULTS:
            if k in saved:
                cfg[k] = saved[k]
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return cfg


def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)


def env_status():
    return {
        "AWS_ACCESS_KEY_ID": bool(os.environ.get("AWS_ACCESS_KEY_ID")),
        "AWS_SECRET_ACCESS_KEY": bool(os.environ.get("AWS_SECRET_ACCESS_KEY")),
        "RESTIC_PASSWORD_FILE": bool(os.environ.get("RESTIC_PASSWORD_FILE")),
        "restic": shutil.which("restic") or "",
        "aws": shutil.which("aws") or "",
    }


# ---------------------------------------------------------------- restic

def run_cmd(args, extra_env=None, timeout=PER_HOST_TIMEOUT):
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    try:
        p = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, env=env
        )
        return p.returncode, (p.stdout or "").strip()
    except FileNotFoundError:
        return 127, ""
    except subprocess.TimeoutExpired:
        return 124, ""


def format_bytes(n):
    try:
        n = int(n)
    except (TypeError, ValueError):
        return "unknown"
    for unit, div in (("TB", 1024 ** 4), ("GB", 1024 ** 3), ("MB", 1024 ** 2)):
        if n >= div:
            v = n / div
            return f"{v:,.2f} {unit}" if unit != "MB" else f"{v:,.1f} {unit}"
    if n >= 1024:
        return f"{n / 1024:,.1f} KB"
    return f"{n} B"


def check_one(hostname, endpoint, bucket):
    """Mirror of check-fleet.ps1 per-laptop logic. Returns a row dict."""
    repo = f"s3:{endpoint}/{bucket}/{hostname}"
    row = {"name": hostname, "status": "", "snapshots": 0,
           "latest": "", "size": "", "sizeBytes": None}

    code, out = run_cmd(["restic", "snapshots", "--json"],
                        {"RESTIC_REPOSITORY": repo})
    if code != 0:
        row["status"] = "FAIL snapshots"
        return row
    try:
        snaps = json.loads(out or "[]")
        if isinstance(snaps, dict):
            snaps = [snaps]
    except json.JSONDecodeError:
        row["status"] = "FAIL parse"
        return row
    row["snapshots"] = len(snaps)
    if snaps:
        times = sorted(s.get("time", "") for s in snaps if isinstance(s, dict))
        row["latest"] = times[-1] if times else ""

    code, out = run_cmd(["restic", "stats", "--mode", "raw-data", "--json"],
                        {"RESTIC_REPOSITORY": repo})
    if code == 0:
        try:
            total = json.loads(out or "{}").get("total_size")
            row["sizeBytes"] = int(total)
            row["size"] = format_bytes(total)
        except (json.JSONDecodeError, TypeError, ValueError):
            row["size"] = "unknown"
    else:
        row["size"] = "unknown"

    row["status"] = "OK" if row["snapshots"] > 0 else "FAIL empty"
    return row


def discover(endpoint, bucket):
    code, out = run_cmd(["aws", "s3api", "list-objects-v2",
                         "--bucket", bucket, "--delimiter", "/",
                         "--endpoint-url", endpoint,
                         "--query", "CommonPrefixes[].Prefix",
                         "--output", "json"])
    if code != 0:
        raise RuntimeError(f"bucket listing failed: {out[:500]}")
    prefixes = json.loads(out or "[]") or []
    return sorted(p.rstrip("/") for p in prefixes if p and p.rstrip("/"))


# ---------------------------------------------------------------- reports

def report_csv(results):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["Name", "Status", "Snapshots", "Latest", "Size", "SizeBytes"])
    for r in results:
        w.writerow([r.get("name", ""), r.get("status", ""),
                    r.get("snapshots", 0), r.get("latest", ""),
                    r.get("size", ""),
                    r.get("sizeBytes") if r.get("sizeBytes") is not None else ""])
    return buf.getvalue()


def report_html(results, endpoint, bucket):
    ok = sum(1 for r in results if r.get("status") == "OK")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rows = "\n".join(
        "<tr><td>{}</td><td class='{}'>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
            html.escape(str(r.get("name", ""))),
            "ok" if r.get("status") == "OK" else "fail",
            html.escape(str(r.get("status", ""))),
            html.escape(str(r.get("snapshots", 0))),
            html.escape(str(r.get("latest", ""))),
            html.escape(str(r.get("size", ""))))
        for r in results)
    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>Mewa Backup and Restore - SP ICT-1 2026-2030 - {html.escape(stamp)}</title>
<style>body{{font-family:sans-serif;margin:2em}}table{{border-collapse:collapse;width:100%}}
th,td{{border:1px solid #ccc;padding:6px 10px;text-align:left}}th{{background:#f0f0f0}}
.ok{{color:green;font-weight:bold}}.fail{{color:red;font-weight:bold}}</style>
</head><body>
<h1>Mewa Backup and Restore - SP ICT-1 2026-2030</h1>
<p>Generated {html.escape(stamp)} - bucket <code>{html.escape(bucket)}</code>
via <code>{html.escape(endpoint)}</code></p>
<p><strong>{ok} OK, {len(results) - ok} FAIL</strong> out of {len(results)} checked.</p>
<table><tr><th>Name</th><th>Status</th><th>Snapshots</th><th>Latest</th><th>Size</th></tr>
{rows}</table>
<p><button onclick="window.print()">Print</button></p>
</body></html>"""


# ---------------------------------------------------------------- web UI

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mewa Backup and Restore - SP ICT-1 2026-2030</title>
<style>
body{font-family:sans-serif;margin:2em;max-width:1000px}
.brand{display:flex;align-items:center;gap:14px}
.brand img{height:56px;width:auto}
textarea{width:100%;height:120px;font-family:monospace}
input[type=text]{width:100%;box-sizing:border-box}
.ok{color:green;font-weight:bold}.fail{color:red;font-weight:bold}
.warn{background:#fff3cd;border:1px solid #e6c200;padding:8px;margin:8px 0}
table{border-collapse:collapse;width:100%;margin-top:1em}
th,td{border:1px solid #ccc;padding:6px 10px;text-align:left}th{background:#f0f0f0}
#bar{height:12px;background:#eee;margin:8px 0}#bar>div{height:100%;width:0;background:#4a90d9}
button{margin:4px 4px 4px 0;padding:6px 12px}
.row{display:flex;gap:12px}.row>div{flex:1}
</style></head><body>
<div class="brand"><img src="/assets/logo.jpeg" alt="Mewa logo"><h1>Mewa Backup and Restore - SP ICT-1 2026-2030</h1></div>
<div id="env"></div>
<h2>Settings</h2>
<div class="row"><div><label>Wasabi endpoint<br><input type="text" id="endpoint"></label></div>
<div><label>Bucket<br><input type="text" id="bucket"></label></div></div>
<label>Hostnames (one per line)<br><textarea id="hosts"></textarea></label><br>
<button onclick="save()">Save settings</button>
<button onclick="discover()">Discover from bucket</button>
<span id="saved"></span>
<h2>Check</h2>
<button id="checkBtn" onclick="startCheck()">Check fleet now</button>
<button id="csvBtn" onclick="dl('csv')" disabled>Download CSV report</button>
<button id="htmlBtn" onclick="dl('html')" disabled>Download HTML report</button>
<div id="bar"><div></div></div>
<div id="summary"></div>
<table id="tbl" hidden><tr><th>Name</th><th>Status</th><th>Snapshots</th><th>Latest</th><th>Size</th></tr></table>
<script>
let jobId=null,timer=null;
async function api(m,p,b){const r=await fetch(p,{method:m,headers:{'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined});if(!r.ok)throw new Error(await r.text());return r.json();}
async function load(){const e=await api('GET','/api/env');const c=await api('GET','/api/config');
document.getElementById('endpoint').value=c.endpoint;document.getElementById('bucket').value=c.bucket;
document.getElementById('hosts').value=(c.hostnames||[]).join('\\n');
let w=[];if(!e.AWS_ACCESS_KEY_ID)w.push('AWS_ACCESS_KEY_ID not set');if(!e.AWS_SECRET_ACCESS_KEY)w.push('AWS_SECRET_ACCESS_KEY not set');
if(!e.RESTIC_PASSWORD_FILE)w.push('RESTIC_PASSWORD_FILE not set');if(!e.restic)w.push('restic not found in PATH');
document.getElementById('env').innerHTML=w.length?'<div class="warn">Server env missing: '+w.join(', ')+'</div>':'';}
async function save(){await api('POST','/api/config',{endpoint:document.getElementById('endpoint').value.trim(),bucket:document.getElementById('bucket').value.trim(),hostnames:document.getElementById('hosts').value.split('\\n').map(s=>s.trim()).filter(Boolean)});
document.getElementById('saved').textContent='Saved.';setTimeout(()=>document.getElementById('saved').textContent='',2000);}
async function discover(){try{const d=await api('POST','/api/discover');document.getElementById('hosts').value=d.hostnames.join('\\n');}catch(e){alert('Discover failed: '+e.message);}}
function hosts(){return document.getElementById('hosts').value.split('\\n').map(s=>s.trim()).filter(Boolean);}
async function startCheck(){const h=hosts();if(!h.length){alert('Enter at least one hostname.');return;}
document.getElementById('checkBtn').disabled=true;document.getElementById('csvBtn').disabled=true;document.getElementById('htmlBtn').disabled=true;
const tbl=document.getElementById('tbl');tbl.hidden=false;while(tbl.rows.length>1)tbl.deleteRow(1);
document.getElementById('summary').textContent='';
const j=await api('POST','/api/check',{hosts:h});jobId=j.jobId;timer=setInterval(poll,2000);poll();}
async function poll(){const j=await api('GET','/api/job?jobId='+encodeURIComponent(jobId));
document.querySelector('#bar>div').style.width=Math.round(j.completed/j.total*100)+'%';
const tbl=document.getElementById('tbl');while(tbl.rows.length>1)tbl.deleteRow(1);
for(const r of j.results){const tr=tbl.insertRow();tr.insertCell().textContent=r.name;
const st=tr.insertCell();st.textContent=r.status;st.className=r.status==='OK'?'ok':'fail';
tr.insertCell().textContent=r.snapshots;tr.insertCell().textContent=r.latest;tr.insertCell().textContent=r.size;}
if(j.done){clearInterval(timer);document.getElementById('checkBtn').disabled=false;
const ok=j.results.filter(r=>r.status==='OK').length;
document.getElementById('summary').textContent=`Checked ${j.results.length}: ${ok} OK, ${j.results.length-ok} FAIL.`;
document.getElementById('csvBtn').disabled=false;document.getElementById('htmlBtn').disabled=false;}}
function dl(kind){window.location='/api/report.'+kind+'?jobId='+encodeURIComponent(jobId);}
load();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "FleetDashboard/1.0"

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _text(self, body, ctype, filename=None, code=200):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        if filename:
            self.send_header("Content-Disposition",
                             f'attachment; filename="{filename}"')
        self.end_headers()
        self.wfile.write(raw)

    def _bytes(self, raw, ctype, code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body_json(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if not n:
            return {}
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/":
            return self._text(PAGE, "text/html; charset=utf-8")
        if url.path == "/assets/logo.jpeg":
            logo = os.path.join(BASE_DIR, "assets", "logo.jpeg")
            if not os.path.isfile(logo):
                return self._text("logo not found", "text/plain", code=404)
            with open(logo, "rb") as f:
                return self._bytes(f.read(), "image/jpeg")
        if url.path == "/api/env":
            return self._json(env_status())
        if url.path == "/api/config":
            return self._json(load_config())
        if url.path == "/api/job":
            q = urllib.parse.parse_qs(url.query)
            with JOBS_LOCK:
                job = JOBS.get((q.get("jobId") or [""])[0])
            if not job:
                return self._json({"error": "unknown job"}, 404)
            with job["lock"]:
                return self._json({"done": job["done"], "total": job["total"],
                                   "completed": job["completed"],
                                   "results": list(job["results"]),
                                   "error": job["error"]})
        if url.path in ("/api/report.csv", "/api/report.html"):
            q = urllib.parse.parse_qs(url.query)
            with JOBS_LOCK:
                job = JOBS.get((q.get("jobId") or [""])[0])
            if not job or not job["done"]:
                return self._text("report not ready", "text/plain", code=404)
            with job["lock"]:
                results = list(job["results"])
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M")
            if url.path.endswith(".csv"):
                return self._text(report_csv(results), "text/csv",
                                  f"fleet-backup-report-{stamp}.csv")
            cfg = load_config()
            return self._text(report_html(results, cfg["endpoint"], cfg["bucket"]),
                              "text/html; charset=utf-8")
        return self._text("not found", "text/plain", code=404)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/api/config":
            data = self._body_json()
            cfg = load_config()
            for k in ("endpoint", "bucket"):
                if isinstance(data.get(k), str) and data[k].strip():
                    cfg[k] = data[k].strip()
            if isinstance(data.get("hostnames"), list):
                cfg["hostnames"] = sorted({str(h).strip() for h in data["hostnames"]
                                           if str(h).strip()})
            save_config(cfg)
            return self._json({"saved": True})
        if url.path == "/api/discover":
            cfg = load_config()
            if not shutil.which("aws"):
                return self._json({"error": "AWS CLI not found on server"}, 500)
            try:
                names = discover(cfg["endpoint"], cfg["bucket"].split("/")[0])
            except Exception as e:  # noqa: BLE001 - surfaced to UI
                return self._json({"error": str(e)}, 500)
            return self._json({"hostnames": names})
        if url.path == "/api/check":
            data = self._body_json()
            hosts = [str(h).strip() for h in (data.get("hosts") or [])]
            hosts = [h for h in dict.fromkeys(hosts) if h]
            if not hosts:
                return self._json({"error": "no hostnames given"}, 400)
            if not shutil.which("restic"):
                return self._json({"error": "restic not found on server"}, 500)
            cfg = load_config()
            job_id = uuid.uuid4().hex
            job = {"done": False, "total": len(hosts), "completed": 0,
                   "results": [], "error": "", "lock": threading.Lock()}
            with JOBS_LOCK:
                JOBS[job_id] = job
            t = threading.Thread(target=_run_job,
                                 args=(job, hosts, cfg["endpoint"], cfg["bucket"]),
                                 daemon=True)
            t.start()
            return self._json({"jobId": job_id})
        return self._text("not found", "text/plain", code=404)


def _run_job(job, hosts, endpoint, bucket):
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
            futs = {ex.submit(check_one, h, endpoint, bucket): h for h in hosts}
            for fut in concurrent.futures.as_completed(futs):
                try:
                    row = fut.result()
                except Exception as e:  # noqa: BLE001 - one host must not kill the job
                    row = {"name": futs[fut], "status": f"FAIL error: {e}",
                           "snapshots": 0, "latest": "", "size": "",
                           "sizeBytes": None}
                with job["lock"]:
                    job["results"].append(row)
                    job["completed"] += 1
        with job["lock"]:
            job["results"].sort(key=lambda r: r["name"].lower())
    except Exception as e:  # noqa: BLE001 - surfaced via /api/job
        with job["lock"]:
            job["error"] = str(e)
    finally:
        with job["lock"]:
            job["done"] = True


def main():
    ap = argparse.ArgumentParser(description="Fleet backup dashboard")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Fleet dashboard on http://{args.host}:{args.port}  (Ctrl+C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
