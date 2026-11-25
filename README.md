[![Scheduled Backup Maintenance Reminders](https://github.com/Salimjjuma/Windows_Backup_and_Recovery/actions/workflows/scheduled-maintenance-issues.yml/badge.svg)](https://github.com/Salimjjuma/Windows_Backup_and_Recovery/actions/workflows/scheduled-maintenance-issues.yml)


# Laptop Documents Backup — Setup Guide (restic + Wasabi)

Internal IT documentation. Companion to the **Backup and Recovery Policy**.

This covers how the automated Documents and Desktop backup system works,
how to provision it for a new laptop, and how to operate/troubleshoot it
once deployed. Read this before running the install script on any machine.

---

## 1. Overview

Each staff laptop runs a background agent that continuously backs up the
user's `Documents` and `Desktop` folders to a dedicated, encrypted [restic](https://restic.net/)
repository stored in a Wasabi S3 bucket.

| Component | What it does |
|---|---|
| `restic` | Backup tool. Encrypts data client-side before upload, deduplicates, versions every snapshot. |
| Wasabi S3 bucket | Remote storage target. One prefix per laptop (or per account with `-PerAccount`), each containing its own repository. |
| `sync-documents.ps1` | Runs continuously on the laptop. Watches Documents + Desktop for changes, triggers backups, prunes old snapshots. |
| `install-backup-agent.ps1` | One-time setup script. Installs restic, provisions the repo, deploys the watcher, registers the scheduled task. |
| `backup-config.json` | Shared endpoint, bucket/prefix and exclude patterns. Read by the installer, the agent and every fleet tool, so they cannot drift apart. |
| `test-restore.ps1` | Run centrally by IT (not on laptops). Restores a snapshot to verify backups are actually recoverable. |
| `verify-backup-agent.ps1` | Read-only health check on a laptop: task state/principal, deployed files, password ACLs, log contents, config, repository and snapshots. Exit code 1 on failure. |

**Encryption:** restic encrypts all data with AES-256 in counter mode
(AES-256-CTR), combined with Poly1305 for integrity verification, by
default. This happens client-side — data leaves the laptop already
encrypted. See §6 for how the encryption password is handled.

**Repository layout:** each laptop gets its own repository, not a shared
one. In the default (legacy) mode that repository is named after
`COMPUTERNAME`. With `-PerAccount` (see §3b) each Windows account gets its
own repository, named `COMPUTERNAME-<account>` (for example
`LAPTOP-1-Acc1`, `LAPTOP-1-Acc2`), so two local accounts on one laptop do
not mix their snapshots, logs or retention.

This avoids lock contention between machines and keeps one laptop's
retention/pruning from affecting another's.

---

## 2. Prerequisites

Before provisioning any laptop, IT needs:

- **A Wasabi bucket** already created (e.g. `s3.eu-south-1.wasabisys.com`).
- **A Wasabi Access Key / Secret Key** for the backup system. This should be
  scoped (via bucket policy) to only the backup bucket — not a full-account
  key. It is entered once per laptop during install; additional accounts on
  the same laptop reuse the saved values.
- **A restic repository password.** This is the encryption password, and is
  a *separate secret from the Wasabi keys*. Use the same password across
  all laptops so any laptop's backups can be restored by IT using one
  shared secret. **Store this password itself in a password manager** —
  if it is lost, backups made with it are permanently unrecoverable.
- **Local admin rights** on the laptop being provisioned (the installer
  self-elevates and will prompt for admin if not already running elevated).
- The script files, kept together in one folder:
  - `install-backup-agent.ps1`
  - `sync-documents.ps1`
  - `backup-config.json` (shared endpoint, bucket/prefix and excludes)
  - `retention.json` (optional; the shared retention policy — without it
    the agent and the fleet tools fall back to 14/8/12. See §10.)
  - (`test-restore.ps1` is only needed on an IT admin machine, not on
    staff laptops)

Before first use, set the endpoint and bucket in `backup-config.json`:

```json
{
  "wasabiEndpoint": "https://s3.eu-south-1.wasabisys.com",
  "bucketAndPrefix": "mewabackup"
}
```

Every script reads that file, so there is no longer a placeholder to edit
in each of `install-backup-agent.ps1`, `test-restore.ps1`, `check-fleet.*`
and `fleet-dashboard.py`. If the file is absent, the built-in defaults
(`eu-south-1` / `mewabackup`) are used, matching the old behaviour. The
same file also carries the `excludes` list that seeds each agent's
`excludes.txt` (see §9).

---

## 3. Provisioning a new laptop

1. Copy `install-backup-agent.ps1`, `sync-documents.ps1` and
   `backup-config.json` (plus `retention.json`, if you have customised it)
   into the same folder on the target laptop.
2. Run PowerShell **as the IT technician performing setup**:
```powershell
   powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1
   # If no user is logged on at install time, or the wrong user is
   # auto-detected, specify the staff owner explicitly:
   # powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1 -TaskUser "DOMAIN\staffuser"
   # If this laptop also needs extra folders backed up (e.g. the Public folder):
   # powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1 -ExtraPaths "C:\Users\Public"
   # Multiple local accounts on this laptop (run once per account; see §3b):
   # powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1 -PerAccount -TaskUser "$env:COMPUTERNAME\Acc1"
   # powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1 -PerAccount -TaskUser "$env:COMPUTERNAME\Acc2"
```
3. It will prompt to elevate (accept the UAC prompt) if not already
   running as admin. Elevation is mandatory: creating the scheduled task
   needs a full administrator token. If UAC is cancelled the installer now
   stops before changing anything (previously it could run through repo
   init and then fail with `Register-ScheduledTask : Access is denied`
   / `0x80070005`). If you see that error, re-run from PowerShell opened
   with **Run as administrator** — it is safe to re-run (existing
   keys/password and repository are reused).
4. When prompted, enter:
   - **Wasabi Access Key ID**
   - **Wasabi Secret Access Key**
   - **restic repository password** (the shared IT-managed password from §2)
5. The script will:
   - Download and install `restic.exe` to `C:\Program Files\restic` (skipped
     if already present)
   - Store the repository password in
     `C:\ProgramData\DocBackup\restic-password.txt`, locked down via
     `icacls` to `SYSTEM`, `Administrators`, and every account whose task
     needs it
   - Set machine-wide environment variables (`AWS_ACCESS_KEY_ID`,
     `AWS_SECRET_ACCESS_KEY`, `RESTIC_PASSWORD_FILE`, and
     `RESTIC_REPOSITORY` in default mode)
   - Run `restic init` to create the encrypted repository (skipped if one
     already exists at that path — safe to re-run the installer)
   - Deploy `sync-documents.ps1` and `backup-config.json` under
     `C:\ProgramData\DocBackup\` (or `...\Accounts\<account>\` with
     `-PerAccount`)
   - Register a Scheduled Task named **`DocumentsBackupSync`** (or
     `DocumentsBackupSync-<account>`) that starts at logon and restarts
     automatically if it stops
   - Start the task immediately for the current session

6. **Verify it worked** — see §5 below before considering the laptop done.

---

## 3b. Multiple accounts on one laptop (per-account mode)

The default install is **one repository/task per laptop**, named after
`COMPUTERNAME`. That is fine for a single-account laptop and is unchanged
for existing deployments. To back up more than one Windows account on the
same machine, use `-PerAccount`, once per account:

```powershell
# Acc1 (admin) — repo LAPTOP-1-Acc1, task DocumentsBackupSync-Acc1
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 `
  -PerAccount -TaskUser "$env:COMPUTERNAME\Acc1"

# Acc2 (standard user) — repo LAPTOP-1-Acc2, task DocumentsBackupSync-Acc2
powershell -ExecutionPolicy Bypass -File .\install-backup-agent.ps1 `
  -PerAccount -TaskUser "$env:COMPUTERNAME\Acc2"
```

What `-PerAccount` changes, compared with the default:

| | Default (legacy) | `-PerAccount` |
|---|---|---|
| Repository | `bucket\COMPUTERNAME` | `bucket\COMPUTERNAME-<account>` |
| Snapshot tag | `COMPUTERNAME` | `COMPUTERNAME-<account>` |
| Scheduled task | `DocumentsBackupSync` | `DocumentsBackupSync-<account>` |
| Logs/state/excludes/extra-paths | `C:\ProgramData\DocBackup\` | `C:\ProgramData\DocBackup\Accounts\<account>\` |
| Password file | `...\DocBackup\restic-password.txt` | same shared file (all task users granted read) |

Each task runs **as its own account** (S4U, limited), so it backs up that
account's own Documents and Desktop automatically — including OneDrive
redirected folders — rather than needing hard-coded paths. Both tasks run
independently and survive lock/logoff.

Notes:

- **`-TaskUser` is mandatory with `-PerAccount`.** Auto-detection prefers the
  console user, so an administrator who elevates to install somebody else's
  agent would silently register their own account. The installer refuses to
  run per-account mode without an explicit `COMPUTER\account`, and verifies
  that the account's profile already exists.
- **Log in as the second account once** before provisioning it, so its
  profile and Desktop exist. After that the agent runs in the background;
  you do not need to keep that account logged in. If the profile is missing
  the installer aborts; if the folders disappear later the agent logs a
  `FATAL: no existing source paths` line and stops instead of backing up
  nothing.
- Installing the second account reuses the machine's saved credentials:
  the prompts show `[Enter to keep existing]` for the Wasabi keys and the
  restic password. Pressing Enter keeps them, so both accounts share the
  same bucket keys and repository password (as intended).
- **Changing the shared restic password is blocked by default.** Overwriting
  `restic-password.txt` does *not* rekey existing repositories — it makes
  every repo that still uses the old key unreadable. The installer refuses
  to replace an existing password unless `-RotateRepositoryPassword` is
  passed, and even then only after you have run `restic key add` on every
  repository (see §6).
- Changing the shared Wasabi keys asks for an explicit `YES` confirmation,
  because running agents keep the old keys until restarted and a typo would
  break their next backup.
- Re-running the installer for one account only touches that account's
  task/repository. It stops the old task, terminates any orphaned watcher
  process, re-registers, starts the task and then verifies it is actually
  running before reporting success. It also preserves the other accounts'
  password-file access. If an existing task with the same name runs as a
  different account (e.g. `Acc 2` and `Acc-2` sanitise to the same name),
  the install aborts rather than overwrite it.
- Each account has its **own** `excludes.txt`, `extra-paths.txt`,
  `retention.json` and `last-prune.txt` under
  `Accounts\<account>\`; changing one does not affect the other. The
  deployed `backup-config.json` is also per account, and is re-written from
  the installer's resolved values on every run.
- `restic snapshots` and the fleet tools see the two repos as separate
  entries (`LAPTOP-1-Acc1`, `LAPTOP-1-Acc2`), so restore testing is per
  account: `test-restore.ps1 -HostName LAPTOP-1-Acc2`.
- **Legacy and per-account mode must not be mixed on one machine.** The
  installer refuses a default (per-laptop) install when
  `DocumentsBackupSync-*` tasks already exist, because it would back up the
  console user's files a second time under `COMPUTERNAME`. During migration,
  remove the legacy agent with `uninstall-backup-agent.ps1` first.
- To remove one account without disturbing the other, use
  `uninstall-backup-agent.ps1 -Account Acc2` (see §8). Shared secrets and
  `restic.exe` are only removed when no backup task remains.

---

## 4. How the ongoing backup works

Once installed, no user action is required. Mechanically:

- On logon, the Scheduled Task launches `sync-documents.ps1` in the
  background (hidden window).
- It runs an **immediate backup on startup**.
- A `FileSystemWatcher` monitors the Documents and Desktop folders. Any change
  (create/edit/delete/rename) starts a **30-second debounce timer** — if no
  further changes occur, a backup runs. This avoids triggering a backup on
  every keystroke of an open file while still capturing changes within
  seconds of them settling.
- A **15-minute failsafe backup** runs regardless, to catch anything missed
  while the laptop was asleep, offline, or the watcher missed an event.
- Every **7 days**, `restic forget --prune` runs to enforce retention
  (default `--keep-daily 14 --keep-weekly 8 --keep-monthly 12`, read from
  `retention.json` — see §10), so the bucket doesn't grow unbounded while
  still preserving a meaningful history.
  The last-prune timestamp is persisted to
  `C:\ProgramData\DocBackup\last-prune.txt` (or
  `...\Accounts\<account>\last-prune.txt`) and restored at startup, so
  a reboot or agent restart does **not** reset the weekly countdown (it
  used to: the timer lived only in script memory).
- Laptops/accounts with extra needs (e.g. the Public folder) list one
  absolute path per line in `extra-paths.txt` (written by
  `install-backup-agent.ps1 -ExtraPaths`, appended on re-runs). In default
  mode that file is `C:\ProgramData\DocBackup\extra-paths.txt`; in
  per-account mode it is
  `C:\ProgramData\DocBackup\Accounts\<account>\extra-paths.txt`. Entries
  are backed up under the same repo and snapshot tag as that agent.
- All activity is logged to `sync.log` next to the agent's config:
  `C:\ProgramData\DocBackup\sync.log` (default) or
  `C:\ProgramData\DocBackup\Accounts\<account>\sync.log` (per-account).

---

## 5. Verifying a laptop after install

Don't consider a laptop provisioned until you've confirmed backups are
actually landing remotely. Run the read-only verifier first — it checks the
task state and principal, deployed files, password-file ACLs, log contents,
config values and (unless `-SkipRepositoryCheck` is passed) that the
repository answers restic and holds snapshots:

```powershell
# Every backup task on this machine (legacy + per-account)
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1

# One account only
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1 -TaskName DocumentsBackupSync-Acc2

# Offline / no Wasabi access: skip the restic calls
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1 -SkipRepositoryCheck
```

It prints one `[PASS]`/`[WARN]`/`[FAIL]` line per check, a summary, and
returns exit code 1 if any check failed (useful for scripting the rollout).
It never changes anything: no tasks are started, no files are written.

To confirm by hand as well:

```powershell
# On the laptop, or remotely with the right env vars set:
restic snapshots
```

You should see at least one snapshot (from the startup backup). In
per-account mode, `restic snapshots` needs that account's repo (`restic -r
s3:.../<bucket>/<COMPUTERNAME>-<account> snapshots`). If the list is empty
or the command errors, check:

- `sync.log` for errors: `C:\ProgramData\DocBackup\sync.log` (default) or
  `C:\ProgramData\DocBackup\Accounts\<account>\sync.log` (per-account)
- That the Scheduled Task is running: `Get-ScheduledTask -TaskName
  DocumentsBackupSync` (or `DocumentsBackupSync-<account>`)
- That the machine env vars are set:
  `[Environment]::GetEnvironmentVariable("RESTIC_REPOSITORY","Machine")`
  (legacy mode; per-account tasks derive their own repo from
  `backup-config.json` + `-BackupId`, so they keep working even when the
  machine-wide value points at the legacy repo)
- If `sync.log` says `Resolving password failed ... Access is denied`, the
  task's account lost read access to `restic-password.txt`: run
  `fix-password-file-access.ps1` (see §8).
- Network/firewall isn't blocking outbound HTTPS to the Wasabi endpoint

---

## 6. Credential and secret handling

There are **two distinct secrets** in this system — don't conflate them:

| Secret | Controls | Where it lives |
|---|---|---|
| Wasabi Access Key / Secret Key | Read/write access to the S3 bucket | Machine-wide env vars (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) on each laptop |
| restic repository password | Decrypts the actual backup contents | `C:\ProgramData\DocBackup\restic-password.txt`, ACL-restricted to SYSTEM, Administrators and every configured backup task user, referenced via `RESTIC_PASSWORD_FILE` |

Someone who obtains only the Wasabi keys can see that encrypted blobs
exist and could delete or overwrite them, but **cannot read the contents**
without the restic password. Treat the restic password as the more
sensitive of the two.

**Rotating the restic repository password** (only if it was exposed):
overwriting `restic-password.txt` alone does **not** rekey anything — every
repository still expects the old key, so the agents would fail with
"wrong password". The safe order is:

1. Run `restic key add` on **every** repository (legacy and each account),
   entering the new password when prompted. The old key remains valid.
2. Update `restic-password.txt` on every laptop, using
   `install-backup-agent.ps1 -RotateRepositoryPassword` (which otherwise
   refuses to replace an existing password). Then restart each backup task.
3. Confirm with `verify-backup-agent.ps1` on each machine.
4. Once every laptop and restore test uses the new key, remove the old key
   with `restic key remove` on each repository.

Keep the old password escrowed until step 4 is complete; without it the
repositories cannot be opened.

**If a laptop is lost or stolen:**
1. Rotate the Wasabi Access Key used by that laptop's install (or the
   shared key, if not laptop-specific) in the Wasabi console.
2. The restic repository password does *not* need to be rotated on the
   remaining laptops unless you believe it was independently exposed
   (e.g. written down, laptop disk unencrypted) — since obtaining it from
   a laptop's ACL-protected file requires the same access that would
   already let someone read the local Documents folder directly.
3. Note the incident against the affected laptop for the next scheduled
   restoration test cycle.

---

## 7. Scheduled restoration testing

Per the Backup and Recovery Policy, backups must be periodically restored
and verified — not just assumed to work. This is done centrally by IT
using `test-restore.ps1`, **not** run on staff laptops.

```powershell
# Run from an IT admin machine with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
# RESTIC_PASSWORD_FILE already set in the environment:
powershell -File test-restore.ps1 -HostName LAPTOP-JSMITH
```

For per-account backups, pass that account's repository prefix, e.g.
`-HostName LAPTOP-JSMITH-Acc2`. Each account is an independent repo, so
each one gets its own integrity check and restore test.

This will:
1. Run `restic check` against that laptop's repository (structural/
   integrity check).
2. Restore the latest snapshot into an isolated folder under
   `C:\RestoreTests\`.
3. Confirm at least one file came back.
4. Log a clear PASS/FAIL line to `C:\RestoreTests\restore-test-log.txt`.
5. Delete the restored test copy afterward (the log persists).

**Recommended cadence:** rotate through all laptops over each quarter (e.g.
~2 laptops/week for 20 laptops), so every machine gets tested at least
once per quarter. Investigate any FAIL immediately — don't wait for the
next cycle.

---

## 8. Common operations

**Check backup status on a specific laptop (remote-in or run locally):**
```powershell
restic snapshots
# Per-account mode: target that account's repo explicitly
restic -r "s3:https://s3.eu-south-1.wasabisys.com/mewabackup/$env:COMPUTERNAME-Acc2" snapshots
```

**Manually trigger a backup:**
```powershell
# Default (legacy) mode: repo comes from RESTIC_REPOSITORY
restic backup "$env:USERPROFILE\Documents" --tag $env:COMPUTERNAME

# Per-account mode: target that account's repo and tag explicitly
restic -r "s3:https://s3.eu-south-1.wasabisys.com/mewabackup/$env:COMPUTERNAME-Acc2" backup "$env:USERPROFILE\Documents" --tag "$env:COMPUTERNAME-Acc2"
# Run this while logged on as Acc2: $env:USERPROFILE must be that account's
# profile, otherwise you would upload the wrong user's files.
```

**Restore a specific file/folder (not a full restore test) to a temp location:**
```powershell
restic restore latest --target C:\Temp\restore --include "path\to\file.docx"

# Per-account restore: point at that account's repo first
restic -r "s3:https://s3.eu-south-1.wasabisys.com/mewabackup/$env:COMPUTERNAME-Acc2" restore latest --target C:\Temp\restore --include "path\to\file.docx"
```

**View recent log activity:**
```powershell
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 50
# Per-account: C:\ProgramData\DocBackup\Accounts\<account>\sync.log
```

**Check when pruning last ran on a laptop:**
```powershell
# Exact timestamp is laptop-local (the state file + sync.log are not
# visible to the central fleet check):
Get-Content C:\ProgramData\DocBackup\last-prune.txt   # ISO 8601 timestamp
Select-String "Retention pruning" C:\ProgramData\DocBackup\sync.log -tail 2
# Per-account: same filenames under C:\ProgramData\DocBackup\Accounts\<account>\
```

**Fleet dashboard (for non-CLI users):**
```powershell
# On the IT admin machine, with the same env vars set as for test-restore.ps1:
python fleet-dashboard.py
# Then open http://127.0.0.1:8080 - enter hostnames (or Discover from the
# bucket), Check fleet now, and download the CSV/HTML report.
# Needs Python 3.8+ and restic on PATH. No packages to install.
```

**Re-run install on a laptop already provisioned** (e.g. to update the
watcher script version): safe to do — `restic init` is skipped if the
repository already exists, and the existing Scheduled Task is stopped, its
orphaned watcher process is terminated, and the task is recreated and
started. The installer then verifies the task is Running and aborts if it
is not. A re-run only affects the account you pass with `-TaskUser` (and
`-PerAccount`). Finish with:

```powershell
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1 -TaskName DocumentsBackupSync-Acc2
```

**Check every agent's health (read-only, safe to script):**
```powershell
powershell -ExecutionPolicy Bypass -File .\verify-backup-agent.ps1
# Exit code 1 means at least one [FAIL]; see its output for the fix.
```

**Repair password-file access** (`Resolving password failed ... Access is
denied` in `sync.log`):
```powershell
# Grants read to SYSTEM, Administrators and every backup task user, then
# restarts the affected task(s). Safe in per-account mode.
powershell -ExecutionPolicy Bypass -File .\fix-password-file-access.ps1
# Optional: restart only one task
powershell -ExecutionPolicy Bypass -File .\fix-password-file-access.ps1 -TaskName DocumentsBackupSync-Acc2
```

**Uninstall / decommission an agent:**
```powershell
# One account of a per-account install (other accounts keep running)
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1 -Account Acc2

# Legacy single-account install
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1

# Also remove this agent's deployed watcher/config/excludes/logs/state
powershell -ExecutionPolicy Bypass -File .\uninstall-backup-agent.ps1 -Account Acc2 -Full
```
The uninstaller stops only that account's task and watcher process. The
shared AWS keys and `restic-password.txt` are deleted only when no
`DocumentsBackupSync*` task remains; `restic.exe` and its PATH entry are
removed only with `-Full` in that same last-agent case. **The remote
repository is never deleted** — archived snapshots stay restorable on
Wasabi (use `restic forget --prune` or the Wasabi console if they must be
purged).

---

## 9. Known limitations / things to watch

- **The fleet dashboard is IT-side only.** `fleet-dashboard.py` runs on the
  IT admin machine and reads the bucket. It does not run on laptops and
  cannot see laptop-local state (`last-prune.txt`, `sync.log`,
  `extra-paths.txt`), so anything that needs that (e.g. "why hasn't this
  pruned yet?") still means logging on to the laptop. It also needs Python
  3.8+ and `restic` on PATH on that machine.
- **Redirected Documents folders.** If a laptop has Documents redirected
  into OneDrive (Known Folder Move), this system will back that up too —
  which is redundant with OneDrive's own sync. Check for this before
  provisioning; it's not harmful, just wasted storage/cost.
- **Debounce means very recent edits (< 30s old) may not be backed up yet**
  if the laptop loses power immediately. The 15-minute failsafe and normal
  save patterns make this a low risk in practice, but it's not
  zero-second RPO.
- **Shared repository password across laptops/accounts** is a deliberate
  trade-off for restore simplicity. If stronger isolation is ever needed
  (e.g. per-laptop passwords), the install script would need to generate
  and separately escrow a unique password per machine/account.
- **Per-account mode increases repository count.** One laptop with two
  accounts is two repos (and two dashboard rows). That is intentional: it
  is what makes per-account retention, restore tests and stale detection
  accurate. Accounts that have never logged on have no profile/Desktop, so
  log in once before provisioning them.
- **`backup-config.json` is per deployment.** Each laptop/account gets a
  copy at install time; after changing the central file, re-run the
  installer for the affected agents (or re-deploy the config) so they pick
  up the new endpoint/bucket. Exclude patterns are seeded into
  `excludes.txt` only when that file does not exist yet — after that, the
  deployed `excludes.txt` is authoritative so local edits are never
  overwritten. To change excludes centrally on an existing agent, update
  its `excludes.txt` (or delete it before re-running the installer).

---

## 10. Reference: script inventory

| File | Runs on | Purpose |
|---|---|---|
| `install-backup-agent.ps1` | Each staff laptop (once); with `-PerAccount`, once per account | Provisions restic, repo, watcher, scheduled task |
| `sync-documents.ps1` | Each staff laptop (continuously, via Scheduled Task) | Watches + backs up + prunes that account's/laptop's repo |
| `uninstall-backup-agent.ps1` | Each staff laptop (on demand) | Removes one agent (`-Account <name>`) or the legacy agent; keeps shared secrets while other agents remain |
| `fix-password-file-access.ps1` | Each staff laptop (on demand) | Repairs `restic-password.txt` read access for all backup task users and restarts them |
| `verify-backup-agent.ps1` | Each staff laptop (after install / on demand) | Read-only health check: task, principal, files, ACLs, log, config, repository, snapshots; exit 1 on failure |
| `backup-config.json` | Repo root + each laptop/account (`C:\ProgramData\DocBackup\` or `...\Accounts\<account>\`) | Single source of endpoint/bucket + exclude patterns, read by every script |
| `test-restore.ps1` | IT admin machine (on a schedule) | Restoration/integrity testing per repository (laptop or account) |
| `check-fleet.ps1` | IT admin machine (on demand) | Lists every laptop/account repo: name, snapshot count, latest time, size, prune backlog |
| `check-fleet.sh` | IT Linux machine (on demand) | Same fleet check as `check-fleet.ps1` for Ubuntu/CI, incl. auto-installing restic/AWS CLI |
| `fleet-dashboard.py` | IT admin machine (local web UI) | Same fleet check as `check-fleet.ps1` in a browser, with CSV/HTML reports |
| `retention.json` | Repo root + each laptop/account (`C:\ProgramData\DocBackup\` or `...\Accounts\<account>\`) | Single source of the prune policy, read by the agent and all three fleet tools |

The **prune backlog** column is computed centrally from each repo's snapshot
list using the same policy the agent prunes with, read from `retention.json`
(defaults: `--keep-daily 14 --keep-weekly 8 --keep-monthly 12` — one snapshot
per day, plus the newest one each week and month within those windows). It
counts the snapshots that policy would still remove. Read it as:

| Backlog shows | Meaning |
|---|---|
| `none pending` | Retention is in force — a forget run now would remove nothing |
| `N snaps (Xd)` | N snapshots have aged out of retention and are still there: the laptop is behind on pruning (typically the agent restarted before each prune window) |
| `unknown` | Snapshots could not be listed, or none had usable timestamps |

Cheapest immediate response to a growing backlog is to log on to that laptop
and check `last-prune.txt` / `sync.log`; `restic forget --prune --tag
<host-or-account>` can also be run centrally earlier than the weekly interval
to bring the repo back within policy.

Questions or issues with this setup should go to [IT lead / distribution
list — fill in].
