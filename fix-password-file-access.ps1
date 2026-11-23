# =====================================================================
# fix-password-file-access.ps1
# Remediation for: "Backup ERROR: Fatal: Resolving password failed:
# Readfile: open C:\ProgramData\DocBackup\restic-password.txt: Access
# is denied."
#
# Cause: restic-password.txt is ACL'd to specific accounts, but a backup
# task runs as an account that was never granted access.
#
# Grants read access to SYSTEM, Administrators, and EVERY configured backup
# task user (legacy DocumentsBackupSync and all DocumentsBackupSync-<account>
# tasks), then restarts the affected task(s). Safe to run in per-account
# mode: it does not drop another account's access.
#
# Run ONCE on any laptop showing the error. No reinstall needed.
# Must be run as Administrator.
# =====================================================================

param(
    # Only restart this task. Default: restart every backup task on the
    # machine (legacy + per-account).
    [string]$TaskName = ""
)

$ErrorActionPreference = "Stop"
# See install-backup-agent.ps1 for why this is needed on PowerShell 7.3+:
# native command non-zero exits (icacls, etc.) would otherwise throw
# instead of just setting $LASTEXITCODE. Harmless no-op on 5.1.
$PSNativeCommandUseErrorActionPreference = $false

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    $fwd = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($TaskName) { $fwd += " -TaskName `"$TaskName`"" }
    Start-Process powershell -Verb RunAs -ArgumentList $fwd
    exit
}

$PasswordFile = "$env:ProgramData\DocBackup\restic-password.txt"

if (-not (Test-Path $PasswordFile)) {
    Write-Host "ERROR: $PasswordFile not found. This laptop may not be provisioned - run install-backup-agent.ps1 instead."
    exit 1
}

# Every backup task on this machine (legacy + per-account).
$allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -like 'DocumentsBackupSync*' })
if ($allTasks.Count -eq 0) {
    Write-Host "ERROR: no DocumentsBackupSync* scheduled task found. Run install-backup-agent.ps1 instead."
    exit 1
}

if ($TaskName) {
    $tasksToRestart = @($allTasks | Where-Object { $_.TaskName -eq $TaskName })
    if ($tasksToRestart.Count -eq 0) {
        Write-Host "WARNING: task '$TaskName' not found; restarting all backup tasks instead."
        $tasksToRestart = $allTasks
    }
} else {
    $tasksToRestart = $allTasks
}

$grantIdentities = @("SYSTEM", "BUILTIN\Administrators") + @($allTasks | ForEach-Object { $_.Principal.UserId })
$seenIds = @{}
$uniqueIds = @()
foreach ($id in $grantIdentities) {
    $t = "$id".Trim()
    if (-not $t) { continue }
    $key = $t.ToLowerInvariant()
    if ($seenIds.ContainsKey($key)) { continue }
    $seenIds[$key] = $true
    $uniqueIds += $t
}

Write-Host "Backup tasks found: $($allTasks.TaskName -join ', ')"
Write-Host "Granting read on $PasswordFile to: $($uniqueIds -join ', ')"

icacls $PasswordFile /inheritance:r | Out-Null
$aclArgs = @($PasswordFile, "/grant:r") + @($uniqueIds | ForEach-Object { "${_}:(R)" })
& icacls @aclArgs | Out-Null

Write-Host "Permissions fixed. Current ACL:"
icacls $PasswordFile

foreach ($t in $tasksToRestart) {
    Write-Host ""
    Write-Host "Restarting $($t.TaskName) to pick up the fix..."
    Stop-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue | Out-Null
    Start-ScheduledTask -TaskName $t.TaskName
}

Write-Host ""
Write-Host "Done. Check each account's sync.log to confirm the next backup succeeds:"
Write-Host "  C:\ProgramData\DocBackup\sync.log                 (legacy)"
Write-Host "  C:\ProgramData\DocBackup\Accounts\<account>\sync.log  (per-account)"
