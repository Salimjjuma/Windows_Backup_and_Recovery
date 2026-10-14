# Laptop Documents Backup — Setup Guide (restic + Wasabi)

Internal IT documentation. Companion to the **Backup and Recovery Policy**.

This covers how the automated Documents-folder backup system works, how to
provision it for a new laptop, and how to operate/troubleshoot it once
deployed. Read this before running the install script on any machine.

---

## 1. Overview

Each staff laptop runs a background agent that continuously backs up the
user's `Documents` and `Desktop` folders to a dedicated, encrypted [restic](https://restic.net/)
repository stored in a Wasabi S3 bucket.

| Component | What it does |
|---|---|
| `restic` | Backup tool. Encrypts data client-side before upload, deduplicates, versions every snapshot. |
| Wasabi S3 bucket | Remote storage target. One prefix per laptop, one repository per laptop. |
| `sync-documents.ps1` | Runs continuously on the laptop. Watches Documents + Desktop for changes, triggers backups, prunes old snapshots. |
| `install-backup-agent.ps1` | One-time setup script. Installs restic, provisions the repo, deploys the watcher, registers the scheduled task. |
| `test-restore.ps1` | Run centrally by IT (not on laptops). Restores a snapshot to verify backups are actually recoverable. |

**Encryption:** restic encrypts all data with AES-256 in counter mode
(AES-256-CTR), combined with Poly1305 for integrity verification, by
default. This happens client-side — data leaves the laptop already
encrypted. See §6 for how the encryption password is handled.

**Repository layout:** each laptop gets its own repository, not a shared
one:

This avoids lock contention between machines and keeps one laptop's
retention/pruning from affecting another's.

---

## 2. Prerequisites

Before provisioning any laptop, IT needs:

- **A Wasabi bucket** already created (e.g. `s3.eu-south-1.wasabisys.com`).
- **A Wasabi Access Key / Secret Key** for the backup system. This should be
  scoped (via bucket policy) to only the backup bucket — not a full-account
  key. It is entered once per laptop during install.
- **A restic repository password.** This is the encryption password, and is
  a *separate secret from the Wasabi keys*. Use the same password across
  all laptops so any laptop's backups can be restored by IT using one
  shared secret. **Store this password itself in a password manager** —
  if it is lost, backups made with it are permanently unrecoverable.
- **Local admin rights** on the laptop being provisioned (the installer
  self-elevates and will prompt for admin if not already running elevated).
- The three script files, kept together in one folder:
  - `install-backup-agent.ps1`
  - `sync-documents.ps1`
  - (`test-restore.ps1` is only needed on an IT admin machine, not on
    staff laptops)

Before first use, open `install-backup-agent.ps1` and `test-restore.ps1`
and replace the placeholder bucket name:

```powershell
$BucketAndPrefix = "mewabackup"   # <-- change to your actual bucket name
```

---

## 3. Provisioning a new laptop

1. Copy `install-backup-agent.ps1` and `sync-documents.ps1` into the same
   folder on the target laptop.
2. Run PowerShell **as the IT technician performing setup**:
```powershell
   powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1
   # If no user is logged on at install time, or the wrong user is
   # auto-detected, specify the staff owner explicitly:
   # powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1 -TaskUser "DOMAIN\staffuser"
```
3. It will prompt to elevate (accept the UAC prompt) if not already
   running as admin.
4. When prompted, enter:
   - **Wasabi Access Key ID**
   - **Wasabi Secret Access Key**
   - **restic repository password** (the shared IT-managed password from §2)
5. The script will:
   - Download and install `restic.exe` to `C:\Program Files\restic` (skipped
     if already present)
   - Store the repository password in
     `C:\ProgramData\DocBackup\restic-password.txt`, locked down via
     `icacls` to `SYSTEM`, `Administrators`, and the staff owner the task runs as
   - Set machine-wide environment variables (`AWS_ACCESS_KEY_ID`,
     `AWS_SECRET_ACCESS_KEY`, `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`)
   - Run `restic init` to create the encrypted repository (skipped if one
     already exists at that path — safe to re-run the installer)
   - Deploy `sync-documents.ps1` to `C:\ProgramData\DocBackup\`
   - Register a Scheduled Task named **`DocumentsBackupSync`** that starts
     at logon and restarts automatically if it stops
   - Start the task immediately for the current session

6. **Verify it worked** — see §5 below before considering the laptop done.

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
  (`--keep-daily 14 --keep-weekly 8 --keep-monthly 12`), so the bucket
  doesn't grow unbounded while still preserving a meaningful history.
- All activity is logged to `C:\ProgramData\DocBackup\sync.log` on the
  laptop itself.

---

## 5. Verifying a laptop after install

Don't consider a laptop provisioned until you've confirmed backups are
actually landing remotely:

```powershell
# On the laptop, or remotely with the right env vars set:
restic snapshots
```

You should see at least one snapshot (from the startup backup). If the
list is empty or the command errors, check:

- `C:\ProgramData\DocBackup\sync.log` for errors
- That the Scheduled Task is running: `Get-ScheduledTask -TaskName DocumentsBackupSync`
- That the machine env vars are set: `[Environment]::GetEnvironmentVariable("RESTIC_REPOSITORY","Machine")`
- Network/firewall isn't blocking outbound HTTPS to the Wasabi endpoint

---

## 6. Credential and secret handling

There are **two distinct secrets** in this system — don't conflate them:

| Secret | Controls | Where it lives |
|---|---|---|
| Wasabi Access Key / Secret Key | Read/write access to the S3 bucket | Machine-wide env vars (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) on each laptop |
| restic repository password | Decrypts the actual backup contents | `C:\ProgramData\DocBackup\restic-password.txt`, ACL-restricted to SYSTEM/Administrators, referenced via `RESTIC_PASSWORD_FILE` |

Someone who obtains only the Wasabi keys can see that encrypted blobs
exist and could delete or overwrite them, but **cannot read the contents**
without the restic password. Treat the restic password as the more
sensitive of the two.

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
```

**Manually trigger a backup:**
```powershell
restic backup "$env:USERPROFILE\Documents" --tag $env:COMPUTERNAME
```

**Restore a specific file/folder (not a full restore test) to a temp location:**
```powershell
restic restore latest --target C:\Temp\restore --include "path\to\file.docx"
```

**View recent log activity:**
```powershell
Get-Content C:\ProgramData\DocBackup\sync.log -Tail 50
```

**Re-run install on a laptop already provisioned** (e.g. to update the
watcher script version): safe to do — `restic init` is skipped if the
repository already exists, and the Scheduled Task is unregistered and
recreated cleanly.

---

## 9. Known limitations / things to watch

- **No central fleet dashboard.** With 20 independently-managed laptops,
  there's no single place to see "which laptops backed up today." Until
  something better is in place, rely on periodic spot checks (`restic
  snapshots` per laptop) and the quarterly restoration test cycle to catch
  silent failures.
- **Redirected Documents folders.** If a laptop has Documents redirected
  into OneDrive (Known Folder Move), this system will back that up too —
  which is redundant with OneDrive's own sync. Check for this before
  provisioning; it's not harmful, just wasted storage/cost.
- **Debounce means very recent edits (< 30s old) may not be backed up yet**
  if the laptop loses power immediately. The 15-minute failsafe and normal
  save patterns make this a low risk in practice, but it's not
  zero-second RPO.
- **Shared repository password across laptops** is a deliberate
  trade-off for restore simplicity. If stronger isolation is ever needed
  (e.g. per-laptop passwords), the install script would need to generate
  and separately escrow a unique password per machine.

---

## 10. Reference: script inventory

| File | Runs on | Purpose |
|---|---|---|
| `install-backup-agent.ps1` | Each staff laptop (once) | Provisions restic, repo, watcher, scheduled task |
| `sync-documents.ps1` | Each staff laptop (continuously, via Scheduled Task) | Watches + backs up + prunes |
| `test-restore.ps1` | IT admin machine (on a schedule) | Restoration/integrity testing across laptops |

Questions or issues with this setup should go to [IT lead / distribution
list — fill in].