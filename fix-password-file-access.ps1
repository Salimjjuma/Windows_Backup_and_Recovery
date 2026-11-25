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

if (-not (Test-Path -LiteralPath $PasswordFile)) {
    Write-Host "ERROR: $PasswordFile not found. This laptop may not be provisioned - run install-backup-agent.ps1 instead."
    exit 1
}

# icacls accepts `*<SID>`; granting by SID avoids localised well-known names
# and mismatches between a task principal stored as a SID and a name-based
# ACL entry.
function Get-AccountSid {
    param([string]$Identity)
    $t = "$Identity".Trim()
    if (-not $t) { return $null }
    if ($t -match '^S-1-5-') { return $t }
    try {
        return (New-Object System.Security.Principal.NTAccount($t)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Resolve-AclIdentity {
    param([string]$Identity)
    $t = "$Identity".Trim()
    if (-not $t) { return $null }
    if ($t -eq 'SYSTEM') { return '*S-1-5-18' }
    if ($t -eq 'BUILTIN\Administrators') { return '*S-1-5-32-544' }
    if ($t -match '^S-1-5-') { return "*$t" }
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($t)).Translate([System.Security.Principal.SecurityIdentifier])
        return "*$($sid.Value)"
    } catch {
        Write-Warning "Could not resolve '$t' to a SID; granting by name instead."
        return $t
    }
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

# Fail if a task runs as an account that cannot be resolved: that account
# would otherwise be silently left without access.
$grantIdentities = @("SYSTEM", "BUILTIN\Administrators")
foreach ($t in $allTasks) {
    $uid = "$($t.Principal.UserId)".Trim()
    if (-not $uid) {
        throw "Task '$($t.TaskName)' has no principal user; cannot work out which account needs password access."
    }
    if (-not (Get-AccountSid -Identity $uid)) {
        throw "Task '$($t.TaskName)' runs as '$uid', which does not resolve on this machine. Fix or remove that task, then re-run."
    }
    $grantIdentities += $uid
}

$seenIds = @{}
$uniqueIds = @()
foreach ($id in $grantIdentities) {
    $resolved = Resolve-AclIdentity -Identity $id
    if (-not $resolved) { continue }
    $key = "$resolved".ToLowerInvariant()
    if ($seenIds.ContainsKey($key)) { continue }
    $seenIds[$key] = $true
    $uniqueIds += $resolved
}

Write-Host "Backup tasks found: $($allTasks.TaskName -join ', ')"
Write-Host "Granting read on $PasswordFile to: $($uniqueIds -join ', ')"

& icacls $PasswordFile /inheritance:r | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "icacls failed to disable inheritance on $PasswordFile (exit code $LASTEXITCODE)."
}
$aclArgs = @($PasswordFile, "/grant:r") + @($uniqueIds | ForEach-Object { "${_}:(R)" })
& icacls @aclArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "icacls failed to grant read access on $PasswordFile (exit code $LASTEXITCODE). Nothing was fixed."
}

Write-Host "Permissions fixed. Current ACL:"
& icacls $PasswordFile

# Per-account agents need to create/append their own sync.log, excludes.txt
# and prune state inside their config directory. Older installs may predate
# the installer's explicit grant, so repair that here too.
function Get-TaskConfigDir {
    param([string]$Arguments)
    if (-not $Arguments) { return $null }
    $m = [regex]::Match($Arguments, '(?:^|\s)-ConfigDir\s+(?:"([^"]*)"|(\S+))')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

foreach ($t in $allTasks) {
    $cfgDir = Get-TaskConfigDir -Arguments "$($t.Actions[0].Arguments)"
    if (-not $cfgDir -or -not (Test-Path -LiteralPath $cfgDir)) { continue }
    $uid = "$($t.Principal.UserId)".Trim()
    if (-not $uid) { continue }
    $dirGrant = "$(Resolve-AclIdentity -Identity $uid):(OI)(CI)M"
    & icacls $cfgDir /grant $dirGrant | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed to grant modify access on $cfgDir to $uid (exit code $LASTEXITCODE)."
    }
    Write-Host "Granted modify on $cfgDir to $uid"
}

$failures = @()
foreach ($t in $tasksToRestart) {
    Write-Host ""
    Write-Host "Restarting $($t.TaskName) to pick up the fix..."
    try {
        Stop-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop | Out-Null
    } catch {
        # A task that is not running refuses to stop; that is fine.
        Write-Host "  (stop skipped: $($_.Exception.Message))"
    }
    $state = ''
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $state = "$((Get-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue).State)"
        if ($state -ne 'Running') { break }
        Start-Sleep -Milliseconds 500
    }
    if ($state -eq 'Running') {
        # It never stopped; starting again would just error. The ACL is read
        # on every restic call, so the running process picks it up anyway.
        Write-Host "  $($t.TaskName) is still running; leaving it up (ACL changes apply immediately)."
        continue
    }
    try {
        Start-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop
    } catch {
        $failures += "$($t.TaskName): could not start - $($_.Exception.Message)"
        continue
    }
    Start-Sleep -Seconds 3
    $state = "$((Get-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue).State)"
    if ($state -ne 'Running') {
        $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue
        $failures += "$($t.TaskName): not running after start (state '$state', LastTaskResult $($info.LastTaskResult))"
    } else {
        Write-Host "  $($t.TaskName) is running."
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: some tasks are not running - backups are stopped until fixed:"
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host ""
Write-Host "Done. Check each account's sync.log to confirm the next backup succeeds:"
Write-Host "  C:\ProgramData\DocBackup\sync.log                 (legacy)"
Write-Host "  C:\ProgramData\DocBackup\Accounts\<account>\sync.log  (per-account)"
