# =====================================================================
# fix-password-file-access.ps1
# Remediation for: "Backup ERROR: Fatal: Resolving password failed:
# Readfile: open C:\ProgramData\DocBackup\restic-password.txt: Access
# is denied."
#
# Cause: restic-password.txt was ACL'd to SYSTEM/Administrators only,
# but the DocumentsBackupSync scheduled task runs as the logged-in
# user, who was never granted access.
#
# Run this ONCE on any laptop already showing the error. No reinstall
# needed. Must be run as Administrator.
# =====================================================================

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$PasswordFile = "$env:ProgramData\DocBackup\restic-password.txt"

if (-not (Test-Path $PasswordFile)) {
    Write-Host "ERROR: $PasswordFile not found. This laptop may not be provisioned - run install-backup-agent.ps1 instead."
    exit 1
}

# Find which user the DocumentsBackupSync task actually runs as
$task = Get-ScheduledTask -TaskName "DocumentsBackupSync" -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "ERROR: DocumentsBackupSync scheduled task not found. Run install-backup-agent.ps1 instead."
    exit 1
}
$TaskUser = $task.Principal.UserId
Write-Host "Scheduled task runs as: $TaskUser"

icacls $PasswordFile /inheritance:r | Out-Null
icacls $PasswordFile /grant:r "SYSTEM:(R)" "BUILTIN\Administrators:(R)" "${TaskUser}:(R)" | Out-Null

Write-Host "Permissions fixed. Current ACL:"
icacls $PasswordFile

Write-Host ""
Write-Host "Restarting DocumentsBackupSync task to pick up the fix..."
Stop-ScheduledTask -TaskName "DocumentsBackupSync" -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName "DocumentsBackupSync"

Write-Host "Done. Check C:\ProgramData\DocBackup\sync.log to confirm the next backup succeeds."