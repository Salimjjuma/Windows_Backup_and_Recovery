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
import base64
import concurrent.futures
import csv
import html
import io
import json
import math
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
    "stale_hours": 24,
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


def pie_svg(items, size=220):
    """Offline SVG pie chart of per-repo byte usage. No JS or CDN needed."""
    total = sum(b for _, b in items)
    if total <= 0 or not items:
        return ""
    cx = cy = size / 2
    r = size / 2 - 10
    parts = []
    angle = -math.pi / 2
    n = len(items)
    for i, (label, b) in enumerate(items):
        color = f"hsl({int(i * 360 / n)} 65% 55%)"
        frac = b / total
        if n == 1:
            parts.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{color}"/>')
            continue
        a2 = angle + frac * 2 * math.pi
        x1, y1 = cx + r * math.cos(angle), cy + r * math.sin(angle)
        x2, y2 = cx + r * math.cos(a2), cy + r * math.sin(a2)
        large = 1 if frac > 0.5 else 0
        parts.append(
            f'<path d="M{cx:.1f},{cy:.1f} L{x1:.1f},{y1:.1f} '
            f'A{r:.1f},{r:.1f} 0 {large},1 {x2:.1f},{y2:.1f} Z" fill="{color}"/>')
        angle = a2
    legend = "\n".join(
        '<li><span style="display:inline-block;width:12px;height:12px;'
        f'background:hsl({int(i * 360 / n)} 65% 55%)"></span> '
        f'{html.escape(label)} - {html.escape(format_bytes(b))} '
        f'({b / total * 100:.1f}%)</li>'
        for i, (label, b) in enumerate(items))
    return (f'<h2>Utilization</h2><div style="display:flex;gap:24px;align-items:center;flex-wrap:wrap">'
            f'<svg width="{size}" height="{size}" viewBox="0 0 {size} {size}">'
            f'{"".join(parts)}</svg><ul class="list-unstyled">{legend}</ul></div>')


def report_html(results, endpoint, bucket):
    ok = sum(1 for r in results if r.get("status") == "OK")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    known = [r.get("sizeBytes") for r in results
             if isinstance(r.get("sizeBytes"), int)]
    total_snaps = sum(r.get("snapshots", 0) for r in results
                      if isinstance(r.get("snapshots"), int))
    if known:
        total_line = (f"Total size used: <strong>{html.escape(format_bytes(sum(known)))}</strong>"
                      f" (across {len(known)} of {len(results)} repositorie(s))")
        total_size_cell = html.escape(format_bytes(sum(known)))
        chart = pie_svg([(str(r.get("name", "")), r.get("sizeBytes"))
                         for r in results
                         if isinstance(r.get("sizeBytes"), int)])
    else:
        total_line = "Total size used: <strong>unknown</strong>"
        total_size_cell = "unknown"
        chart = ""
    try:
        with open(os.path.join(BASE_DIR, "assets", "logo.jpeg"), "rb") as f:
            logo_img = ('<img src="data:image/jpeg;base64,{}" alt="Mewa logo" '
                        'style="height:56px;width:auto">').format(
                            base64.b64encode(f.read()).decode("ascii"))
    except OSError:
        logo_img = ""
    rows = "\n".join(
        "<tr><td>{}</td><td class='{}'>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
            html.escape(str(r.get("name", ""))),
            "text-success fw-bold" if r.get("status") == "OK" else "text-danger fw-bold",
            html.escape(str(r.get("status", ""))),
            html.escape(str(r.get("snapshots", 0))),
            html.escape(str(r.get("latest", ""))),
            html.escape(str(r.get("size", ""))))
        for r in results)
    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>Mewa Backup and Restore - SP ICT-1 2026-2030 - {html.escape(stamp)}</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
</head><body>
<nav class="navbar navbar-dark bg-dark mb-4"><div class="container">
<span class="navbar-brand d-flex align-items-center gap-3">{logo_img}Mewa Backup and Restore - SP ICT-1 2026-2030</span>
</div></nav>
<div class="container" style="max-width:1000px">
<table class="table table-bordered w-auto"><tr><th>Generated</th><th>Bucket</th><th>Endpoint</th></tr>
<tr><td>{html.escape(stamp)}</td><td><code>{html.escape(bucket)}</code></td><td><code>{html.escape(endpoint)}</code></td></tr></table>
<p class="alert alert-info"><strong>{ok} OK, {len(results) - ok} FAIL</strong> out of {len(results)} checked.<br>{total_line}.</p>
<table class="table table-striped table-hover"><thead class="table-light"><tr><th>Name</th><th>Status</th><th>Snapshots</th><th>Latest</th><th>Size</th></tr></thead><tbody>
{rows}
<tr class="table-group-divider fw-bold"><td>Total</td><td></td><td>{total_snaps}</td><td></td><td>{total_size_cell}</td></tr></tbody></table>
{chart}
<p><button class="btn btn-secondary d-print-none" onclick="window.print()">Print</button></p>
<footer class="mt-4 pt-3 border-top text-muted d-flex justify-content-between flex-wrap gap-2"><span>Prepared By: ICT Department</span><span>Report generated: {html.escape(stamp)}</span></footer>
</div></body></html>"""


# ---------------------------------------------------------------- web UI

PAGE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mewa Backup and Restore - SP ICT-1 2026-2030</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
<style>
textarea{height:120px;font-family:monospace}
label.form-label{display:block}
.ok{color:var(--bs-success);font-weight:bold}.fail{color:var(--bs-danger);font-weight:bold}
.navbar-brand img{height:40px;width:auto}
#tbl{margin-top:1em}
#tbl th{cursor:pointer;user-select:none;white-space:nowrap}
</style></head><body>
<nav class="navbar navbar-dark bg-dark mb-4"><div class="container">
<a class="navbar-brand d-flex align-items-center gap-3" href="#"><img src="/assets/logo.jpeg" alt="Mewa logo"><span>Mewa Backup and Restore - SP ICT-1 2026-2030</span></a>
</div></nav>
<div class="container" style="max-width:1000px">
<div id="env"></div>
<div class="card mb-4"><div class="card-body">
<h2 class="card-title h4">Settings</h2>
<div class="row g-3"><div class="col-md-4"><label class="form-label">Wasabi endpoint<input type="text" class="form-control" id="endpoint"></label></div>
<div class="col-md-4"><label class="form-label">Bucket<input type="text" class="form-control" id="bucket"></label></div>
<div class="col-md-4"><label class="form-label">Stale threshold (hours)<input type="number" class="form-control" id="staleHours" min="1" max="720"></label></div></div>
<label class="form-label mt-3">Hostnames (one per line)<textarea class="form-control" id="hosts"></textarea></label>
<div class="mt-3"><button class="btn btn-primary" onclick="save()">Save settings</button>
<button id="discBtn" class="btn btn-outline-secondary" onclick="discover()">Discover from bucket</button>
<span id="saved" class="text-muted ms-2"></span></div>
</div></div>
<div class="card mb-4"><div class="card-body">
<h2 class="card-title h4">Check</h2>
<button id="checkBtn" class="btn btn-success" onclick="startCheck()">Check fleet now</button>
<button id="csvBtn" class="btn btn-outline-secondary" onclick="dl('csv')" disabled>Download CSV report</button>
<button id="htmlBtn" class="btn btn-outline-secondary" onclick="dl('html')" disabled>Download HTML report</button>
<div id="bar" class="progress mt-3"><div class="progress-bar" role="progressbar" style="width:0%"></div></div>
<div id="summary" class="mt-2"></div>
<div class="form-check mt-2"><input class="form-check-input" type="checkbox" id="failOnly" onchange="renderTable()"><label class="form-check-label" for="failOnly">Show failures only</label></div>
<table id="tbl" class="table table-striped table-hover" hidden><thead class="table-light"><tr><th onclick="sortBy(0)" title="Sort">Name<span id="arr0"></span></th><th onclick="sortBy(1)" title="Sort">Status<span id="arr1"></span></th><th onclick="sortBy(2)" title="Sort">Snapshots<span id="arr2"></span></th><th onclick="sortBy(3)" title="Sort">Latest<span id="arr3"></span></th><th onclick="sortBy(4)" title="Sort">Size<span id="arr4"></span></th></tr></thead></table>
<script>
let jobId=null,timer=null,staleHrs=24,lastResults=[],sortCol=-1,sortDir=1;
function sortBy(n){if(sortCol===n){sortDir=-sortDir;}else{sortCol=n;sortDir=1;}renderTable();}
function cmpRows(a,b,c){
if(c===2)return (a.snapshots||0)-(b.snapshots||0);
if(c===3)return String(a.latest||'').localeCompare(String(b.latest||''));
if(c===4)return ((typeof a.sizeBytes==='number')?a.sizeBytes:-1)-((typeof b.sizeBytes==='number')?b.sizeBytes:-1);
if(c===1)return String(a.status||'').localeCompare(String(b.status||''));
return String(a.name||'').localeCompare(String(b.name||''));}
function renderTable(){
const tbl=document.getElementById('tbl');while(tbl.rows.length>1)tbl.deleteRow(1);
let rows=lastResults.slice();
if(document.getElementById('failOnly').checked)rows=rows.filter(r=>r.status!=='OK');
if(sortCol>=0)rows.sort((a,b)=>cmpRows(a,b,sortCol)*sortDir);
for(const r of rows){const tr=tbl.insertRow();tr.insertCell().textContent=r.name;
const st=tr.insertCell();st.textContent=r.status;st.className=r.status==='OK'?'ok':'fail';
tr.insertCell().textContent=r.snapshots;const lt=tr.insertCell();lt.textContent=r.latest;
const t=r.latest?Date.parse(r.latest):NaN;
if(!isNaN(t)&&Date.now()-t>staleHrs*3600e3){lt.className='text-danger fw-bold';lt.title='Stale: no snapshot within '+staleHrs+'h';}
tr.insertCell().textContent=r.size;}
for(let i=0;i<5;i++){const s=document.getElementById('arr'+i);if(s)s.textContent=(i===sortCol?(sortDir>0?' ▲':' ▼'):'');}}
function fmtBytes(n){if(n>=1099511627776)return (n/1099511627776).toFixed(2)+' TB';if(n>=1073741824)return (n/1073741824).toFixed(2)+' GB';if(n>=1048576)return (n/1048576).toFixed(1)+' MB';if(n>=1024)return (n/1024).toFixed(1)+' KB';return n+' B';}
async function api(m,p,b){const r=await fetch(p,{method:m,headers:{'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined});if(!r.ok)throw new Error(await r.text());return r.json();}
async function load(){const e=await api('GET','/api/env');const c=await api('GET','/api/config');
document.getElementById('endpoint').value=c.endpoint;document.getElementById('bucket').value=c.bucket;
document.getElementById('hosts').value=(c.hostnames||[]).join('\\n');
staleHrs=parseInt(c.stale_hours)||24;document.getElementById('staleHours').value=staleHrs;
let w=[];if(!e.AWS_ACCESS_KEY_ID)w.push('AWS_ACCESS_KEY_ID not set');if(!e.AWS_SECRET_ACCESS_KEY)w.push('AWS_SECRET_ACCESS_KEY not set');
if(!e.RESTIC_PASSWORD_FILE)w.push('RESTIC_PASSWORD_FILE not set');if(!e.restic)w.push('restic not found in PATH');
document.getElementById('env').innerHTML=w.length?'<div class="alert alert-warning" role="alert">Server env missing: '+w.join(', ')+'</div>':'';}
async function save(){staleHrs=Math.min(720,Math.max(1,parseInt(document.getElementById('staleHours').value)||24));
await api('POST','/api/config',{endpoint:document.getElementById('endpoint').value.trim(),bucket:document.getElementById('bucket').value.trim(),hostnames:document.getElementById('hosts').value.split('\\n').map(s=>s.trim()).filter(Boolean),stale_hours:staleHrs});
document.getElementById('saved').textContent='Saved.';setTimeout(()=>document.getElementById('saved').textContent='',2000);}
async function discover(){const b=document.getElementById('discBtn');const orig=b.innerHTML;
b.disabled=true;b.innerHTML='<span class="spinner-border spinner-border-sm" role="status"></span> Discovering…';
try{const d=await api('POST','/api/discover');document.getElementById('hosts').value=d.hostnames.join('\\n');}
catch(e){alert('Discover failed: '+e.message);}
finally{b.disabled=false;b.innerHTML=orig;}}
function hosts(){return document.getElementById('hosts').value.split('\\n').map(s=>s.trim()).filter(Boolean);}
async function startCheck(){const h=hosts();if(!h.length){alert('Enter at least one hostname.');return;}
document.getElementById('checkBtn').disabled=true;document.getElementById('csvBtn').disabled=true;document.getElementById('htmlBtn').disabled=true;
const tbl=document.getElementById('tbl');tbl.hidden=false;while(tbl.rows.length>1)tbl.deleteRow(1);
document.getElementById('summary').className='mt-2';
const j=await api('POST','/api/check',{hosts:h});jobId=j.jobId;timer=setInterval(poll,2000);poll();}
async function poll(){const j=await api('GET','/api/job?jobId='+encodeURIComponent(jobId));
document.querySelector('#bar>div').style.width=Math.round(j.completed/j.total*100)+'%';
lastResults=j.results;renderTable();
if(j.done){clearInterval(timer);document.getElementById('checkBtn').disabled=false;
const ok=j.results.filter(r=>r.status==='OK').length;
document.getElementById('summary').className='alert alert-info mt-2';
const known=j.results.filter(r=>typeof r.sizeBytes==='number');
const tot=known.reduce((a,r)=>a+r.sizeBytes,0);
document.getElementById('summary').textContent=`Checked ${j.results.length}: ${ok} OK, ${j.results.length-ok} FAIL.`+(known.length?` Total size used: ${fmtBytes(tot)} (across ${known.length} of ${j.results.length}).`:'');
document.getElementById('csvBtn').disabled=false;document.getElementById('htmlBtn').disabled=false;}}
function dl(kind){window.location='/api/report.'+kind+'?jobId='+encodeURIComponent(jobId);}
load();
</script></div></body></html>"""


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
            sh = data.get("stale_hours")
            if isinstance(sh, (int, float)) and 1 <= sh <= 720:
                cfg["stale_hours"] = int(sh)
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
