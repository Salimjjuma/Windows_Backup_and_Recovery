# Commands

Copy-paste reference for the laptop backup system (restic + Wasabi).
Run laptop sections **on the laptop**, IT-admin sections **on the IT machine**.

---

## 1. Install (laptop, run as IT technician)

```powershell
# Basic install (prompts: Wasabi keys, restic password, extra folders)
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1

# Staff owner is not the logged-on user (or nobody logged on)
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -TaskUser "DOMAIN\staffuser"

# With extra folders, no prompt for them
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -ExtraPaths "C:\Users\Public"
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -ExtraPaths "C:\Users\Public","D:\Work"

# Re-run (e.g. deploy a new watcher version, or add -ExtraPaths).
# Saved keys/password are offered as [Enter to keep] — type only to rotate.
# restic init is skipped if the repo exists; task is recreated cleanly.
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1
```

What install does: restic → `C:\Program Files\restic`, password → `C:\ProgramData\DocBackup\restic-password.txt` (ACL'd), machine env vars, `restic init`, watcher → `C:\ProgramData\DocBackup\sync-documents.ps1`, task `DocumentsBackupSync` (logon trigger, auto-restart), starts it.

## 2. Verify after install (laptop)

```powershell
restic snapshots
Get-ScheduledTask -TaskName DocumentsBackupSync
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 50
[Environment]::GetEnvironmentVariable("RESTIC_REPOSITORY", "Machine")
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator")  # must be True for install/uninstall
```

Expect: ≥1 snapshot, task `Ready/Running`, log shows `Backup completed successfully`.

## 3. Extra backup folders (laptop, any time after install)

```powershell
# Option A: command line (no reinstall, no key prompts)
Add-Content C:\ProgramData\DocBackup\extra-paths.txt "D:\NewFolder"
Restart-ScheduledTask -TaskName DocumentsBackupSync

# Option B: open C:\ProgramData\DocBackup\extra-paths.txt in Notepad,
# add one absolute path per line (# = comment), save, then:
Restart-ScheduledTask -TaskName DocumentsBackupSync

# Confirm it was picked up (watcher reads the file once at startup)
Get-Content C:\ProgramData\DocBackup\extra-paths.txt
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 10   # "Watched paths:" includes the new folder
```

## 4. Manual backup / restore (laptop)

```powershell
# Manual backup of Documents now
restic backup "$env:USERPROFILE\Documents" --tag $env:COMPUTERNAME

# Restore one file to a temp location (never over the original)
restic restore latest --target C:\Temp\restore --include "path\to\file.docx"

# View recent log activity
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 50
```

## 5. Task control (laptop, admin)

```powershell
Start-ScheduledTask -TaskName DocumentsBackupSync
Stop-ScheduledTask -TaskName DocumentsBackupSync
Restart-ScheduledTask -TaskName DocumentsBackupSync
Get-ScheduledTask -TaskName DocumentsBackupSync | Select State, LastRunTime, LastTaskResult
```

## 6. Uninstall (laptop, admin)

```powershell
# Stops task + watchers, deletes 4 machine env vars, deletes restic-password.txt.
# Keeps restic.exe, logs, excludes.
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1

# Full wipe: also removes restic.exe, deployed watcher, excludes/extra-paths, logs
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1 -Full
```

## 7. Fleet checks (IT admin machine)

```powershell
# Prerequisites on the IT machine (same as test-restore):
# $env:AWS_ACCESS_KEY_ID, $env:AWS_SECRET_ACCESS_KEY, $env:RESTIC_PASSWORD_FILE set; restic on PATH.

# Check named laptops
powershell -File .\check-fleet.ps1 -HostNames LAPTOP-1,LAPTOP-2

# Discover all repos via AWS CLI (needs: aws on PATH)
powershell -File .\check-fleet.ps1
```

```powershell
# Browser dashboard instead of CLI (Python 3.8+, no pip packages; restic on PATH)
python fleet-dashboard.py
# open http://127.0.0.1:8080 -> enter hostnames (or Discover), Check fleet now, download CSV/HTML
python fleet-dashboard.py --port 8080
```

## 8. Restoration tests (IT admin machine)

```powershell
# Integrity check + restore latest snapshot to C:\RestoreTests\<host>-<stamp>\, logs PASS/FAIL, cleans up
powershell -File .\test-restore.ps1 -HostName LAPTOP-JSMITH
Get-Content C:\RestoreTests\restore-test-log.txt -Tail 20
```

Recommended cadence: rotate through all laptops quarterly (~2/week for 20 laptops); investigate FAIL immediately.

## 9. Wasabi access test / first repo init (any machine with restic)

```powershell
$env:AWS_ACCESS_KEY_ID="<key>"
$env:AWS_SECRET_ACCESS_KEY="<secret>"
$env:RESTIC_REPOSITORY="s3:https://s3.eu-south-1.wasabisys.com/mewabackup/$env:COMPUTERNAME"
$env:RESTIC_PASSWORD="<shared-repo-password>"
restic init --verbose   # run once per laptop repo; skipped by installer if it exists
restic snapshots
```

```powershell
# S3-level test (needs AWS CLI) — fails here too = keys/policy/bucket, restic is innocent
aws s3 ls s3://mewabackup --endpoint-url https://s3.eu-south-1.wasabisys.com
```

## 10. Fix: password-file access denied (laptop, admin)

Symptom in `sync.log`: `open C:\ProgramData\DocBackup\restic-password.txt: Access is denied.`

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-password-file-access.ps1
```
