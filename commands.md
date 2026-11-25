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

# Multiple local accounts on one laptop: run once per account with -PerAccount.
# Each gets its own repo/task/log dir (COMPUTERNAME-Acc1, COMPUTERNAME-Acc2).
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -PerAccount -TaskUser "$env:COMPUTERNAME\Acc1"
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -PerAccount -TaskUser "$env:COMPUTERNAME\Acc2"

# With extra folders, no prompt for them
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -ExtraPaths "C:\Users\Public"
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -ExtraPaths "C:\Users\Public","D:\Work"

# Re-run (e.g. deploy a new watcher version, or add -ExtraPaths).
# Saved keys/password are offered as [Enter to keep]; a changed password is
# REJECTED unless -RotateRepositoryPassword is passed (overwriting the file
# does not rekey existing repos). The old task is stopped, an orphaned
# watcher is killed, and the new task is started and verified.
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1

# Only during a planned password rotation (run `restic key add` on every repo first)
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -RotateRepositoryPassword
```

Note: `-PerAccount` requires `-TaskUser`. A default (legacy) install is
refused on a machine that already has `DocumentsBackupSync-*` tasks, to
avoid a second agent backing up the console user's files under
`COMPUTERNAME`.

What install does: restic → `C:\Program Files\restic`, password → `C:\ProgramData\DocBackup\restic-password.txt` (ACL'd; read access granted to every configured backup task user), machine env vars, `restic init`, watcher → `C:\ProgramData\DocBackup\sync-documents.ps1`, shared config → `C:\ProgramData\DocBackup\backup-config.json`, retention policy → `C:\ProgramData\DocBackup\retention.json` (kept if already present), task `DocumentsBackupSync` (logon trigger, auto-restart), starts it.

With `-PerAccount`, the same steps use `COMPUTERNAME-<account>` as the repo/tag, `DocumentsBackupSync-<account>` as the task, and `C:\ProgramData\DocBackup\Accounts\<account>\` for the watcher/logs/excludes/extra-paths; the password file and AWS keys remain shared.

## 2. Verify after install (laptop)

```powershell
# Automated read-only health check (recommended). Exit code 1 = a [FAIL].
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1 -TaskName DocumentsBackupSync-Acc2
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1 -SkipRepositoryCheck   # no network

# Default / legacy
restic snapshots
Get-ScheduledTask -TaskName DocumentsBackupSync
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 50
[Environment]::GetEnvironmentVariable("RESTIC_REPOSITORY", "Machine")

# Per-account (repo/tag = COMPUTERNAME-<account>)
restic -r "s3:https://s3.eu-south-1.wasabisys.com/mewabackup/$env:COMPUTERNAME-Acc2" snapshots
Get-ScheduledTask -TaskName DocumentsBackupSync-Acc2
Get-Content C:\ProgramData\DocBackup\Accounts\Acc2\sync.log -Tail 50

# Must be True for install/uninstall
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator")
```

Expect: ≥1 snapshot, task `Running`, log shows `Backup completed successfully`,
`verify-backup-agent.ps1` prints `RESULT: PASS`. The literal endpoint/bucket in
the commands above are the defaults; if `backup-config.json` has other values,
substitute those.

## 3. Extra backup folders (laptop, any time after install)

```powershell
# Option A: command line (no reinstall, no key prompts)
Add-Content C:\ProgramData\DocBackup\extra-paths.txt "D:\NewFolder"
Restart-ScheduledTask -TaskName DocumentsBackupSync

# Per-account: use that account's file and task
Add-Content C:\ProgramData\DocBackup\Accounts\Acc2\extra-paths.txt "D:\NewFolder"
Restart-ScheduledTask -TaskName DocumentsBackupSync-Acc2

# Option B: open C:\ProgramData\DocBackup\extra-paths.txt in Notepad,
# add one absolute path per line (# = comment), save, then:
Restart-ScheduledTask -TaskName DocumentsBackupSync

# Confirm it was picked up (watcher reads the file once at startup)
Get-Content C:\ProgramData\DocBackup\extra-paths.txt
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 10   # "Watched paths:" includes the new folder
```

## 3b. Retention policy (laptop, admin)

The prune policy lives in `retention.json`, deployed to
`C:\ProgramData\DocBackup\retention.json`. The agent and all three fleet tools
read the same file, so changing it changes both what gets pruned and what the
dashboard's **Prune backlog** column expects.

```powershell
# Show the effective policy + what the agent loaded at startup
Get-Content C:\ProgramData\DocBackup\retention.json
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 20 | Select-String "Retention policy"

# Change it (snapshots to keep per day/week/month), then restart the agent
notepad C:\ProgramData\DocBackup\retention.json   # {"keepDaily":14,"keepWeekly":8,"keepMonthly":12}
Restart-ScheduledTask -TaskName DocumentsBackupSync

# Per-account: each account has its own copy + task
notepad C:\ProgramData\DocBackup\Accounts\Acc2\retention.json
Restart-ScheduledTask -TaskName DocumentsBackupSync-Acc2
```

Missing or invalid file falls back to 14/8/12. If you change a laptop's copy,
update the repo copy too — otherwise the fleet check evaluates the backlog
against the old policy.

## 4. Manual backup / restore (laptop)

```powershell
# Manual backup of Documents now (default / legacy)
restic backup "$env:USERPROFILE\Documents" --tag $env:COMPUTERNAME

# Per-account: target the account's repo + tag explicitly
restic -r "s3:https://s3.eu-south-1.wasabisys.com/mewabackup/$env:COMPUTERNAME-Acc2" backup "$env:USERPROFILE\Documents" --tag "$env:COMPUTERNAME-Acc2"

# Restore one file to a temp location (never over the original)
restic restore latest --target C:\Temp\restore --include "path\to\file.docx"
# Per-account restore: add -r "<repo>"; restore "latest" from that account's repo only

# View recent log activity
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 50
```

## 5. Task control (laptop, admin)

```powershell
Start-ScheduledTask -TaskName DocumentsBackupSync
Stop-ScheduledTask -TaskName DocumentsBackupSync
Restart-ScheduledTask -TaskName DocumentsBackupSync
Get-ScheduledTask -TaskName DocumentsBackupSync | Select State, LastRunTime, LastTaskResult

# Per-account: use DocumentsBackupSync-<account>
Get-ScheduledTask -TaskName DocumentsBackupSync-Acc2 | Select State, LastRunTime, LastTaskResult
Restart-ScheduledTask -TaskName DocumentsBackupSync-Acc2

# List every backup task on the machine
Get-ScheduledTask | Where-Object { $_.TaskName -like 'DocumentsBackupSync*' } | Select TaskName, State
```

## 6. Uninstall (laptop, admin)

```powershell
# Stops that task + its watcher. Deletes the 4 shared machine env vars and
# restic-password.txt ONLY if no other backup task remains.
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1

# Per-account: remove only one account's agent (other accounts stay intact)
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1 -Account Acc2

# Full wipe of this agent: also removes its deployed watcher/config/excludes/logs.
# restic.exe + shared secrets are removed only when no backup task remains.
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1 -Account Acc2 -Full
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
# Click a column header to sort (again to reverse); "Show failures only" filters.
# Click a laptop name to expand its 10 most recent snapshots. Latest cells older
# than the Stale threshold (Settings, default 24h) highlight red.
# "Prune backlog" column: snapshots the retention policy (retention.json; one
# per day, plus one per week/month) would still remove - >0 red means that
# laptop's agent is behind on pruning; check last-prune.txt / sync.log.
# Growth card tracks total fleet size over time (logged per check on the IT
# machine only — no Wasabi/laptop changes); needs a few weeks of checks to fill in.
python fleet-dashboard.py --port 8080
```

### 7b. Fleet checks from Linux / Ubuntu (IT admin machine or any Linux box)

Same checks as `check-fleet.ps1`, no manual setup: `./check-fleet.sh`
auto-installs `restic` (latest GitHub release) and, only for auto-discovery,
AWS CLI v2 (via `sudo apt-get` / official installers).

```bash
chmod +x check-fleet.sh

# Credentials (scoped backup-laptops user is enough; root keys also work):
export AWS_ACCESS_KEY_ID="<key>"
export AWS_SECRET_ACCESS_KEY="<secret>"
export RESTIC_PASSWORD_FILE="$HOME/.restic-password"   # chmod 600, never commit
# optional overrides (defaults: eu-south-1 / mewabackup):
# export WASABI_ENDPOINT="https://s3.eu-south-1.wasabisys.com"
# export BUCKET="mewabackup"

# Explicit hostnames (no AWS CLI needed):
./check-fleet.sh LAPTOP-1 LAPTOP-2
./check-fleet.sh --hostnames LAPTOP-1,LAPTOP-2 --csv fleet.csv

# Discover all repos via AWS CLI:
./check-fleet.sh
```

Exit code is 1 if any laptop FAILs (usable in cron/CI).

Per-account backups appear as separate repositories/labels, e.g.
`LAPTOP-1-Acc1` and `LAPTOP-1-Acc2`. Pass those names to the fleet tools
(or let discovery list them) — no other change is needed.

## 8. Restoration tests (IT admin machine)

```powershell
# Integrity check + restore latest snapshot to C:\RestoreTests\<host>-<stamp>\, logs PASS/FAIL, cleans up
powershell -File .\test-restore.ps1 -HostName LAPTOP-JSMITH
Get-Content C:\RestoreTests\restore-test-log.txt -Tail 20

# Per-account: test that account's repo independently
powershell -File .\test-restore.ps1 -HostName LAPTOP-JSMITH-Acc2
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

Per-account repos use `$env:COMPUTERNAME-Acc1` (etc.) instead of
`$env:COMPUTERNAME`; the installer creates them automatically.

```powershell
# S3-level test (needs AWS CLI) — fails here too = keys/policy/bucket, restic is innocent
aws s3 ls s3://mewabackup --endpoint-url https://s3.eu-south-1.wasabisys.com
```

## 10. Fix: password-file access denied (laptop, admin)

Symptom in `sync.log`: `open C:\ProgramData\DocBackup\restic-password.txt: Access is denied.`

```powershell
# Default / legacy
powershell -ExecutionPolicy Bypass -File .\fix-password-file-access.ps1
```

The fix grants read to SYSTEM, Administrators and **all** configured backup
task users, then restarts every backup task (and exits 1 if one does not come
back up), so it is safe to run on a per-account machine without locking
another account out. Confirm with `verify-backup-agent.ps1` afterwards.

The script also takes ownership (`takeown /f ... /a`) and retries if
`icacls` is refused, which is what happens when an earlier install ran
without elevation and left `restic-password.txt` owned by the task account.

## 11. Fix: `Register-ScheduledTask : Access is denied` on install

Symptom: the installer gets through restic/password/config deployment, then
stops at:

```
Register-ScheduledTask : Access is denied.
FullyQualifiedErrorId : HRESULT 0x80070005,Register-ScheduledTask
```

Cause: the script was started from a non-elevated PowerShell (or via an
account that is not an administrator). Task Scheduler refuses to create a
task that runs whether-or-not-logged-on (S4U) in the root task folder
without a full administrator token. The `Relaunching as Administrator...`
path only works if that administrator prompt is accepted; if it is
cancelled or UAC is unavailable, the original non-elevated process keeps
running.

Fix: open PowerShell with **Run as administrator**, then re-run the same
command:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 -PerAccount -TaskUser "$env:COMPUTERNAME\test"
```

A re-run is safe and expected: at the key/password prompts press Enter to
keep the existing values, the repository already exists so `restic init` is
skipped, and the deployed files are simply replaced. Current builds abort at
startup if elevation is missing and read back the machine environment
variables, so this failure now happens before anything is changed.

If it still fails when elevated, collect:

```powershell
whoami /groups | findstr /i "S-1-5-32-544"
whoami /priv | findstr /i "SeTcbPrivilege SeTakeOwnershipPrivilege"
Get-ScheduledTask -TaskName "DocumentsBackupSync-test" -ErrorAction SilentlyContinue
# Task Scheduler operational log, last 20 events:
Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational -MaxEvents 20 |
    Where-Object { $_.Id -in 101,102,103,104,111,201 } | Format-List TimeCreated, Id, Message
```

Also confirm the task account is a real, enabled local account with a
loaded profile (`Test-Path "$env:SystemDrive\Users\test"`), and that the
account can be used for a scheduled task (blank-password accounts are
restricted by policy).
