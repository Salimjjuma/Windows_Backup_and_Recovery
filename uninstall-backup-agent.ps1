# =====================================================================
# uninstall-backup-agent.ps1
# Removes a Documents backup agent provisioned by
# install-backup-agent.ps1. Run as Administrator.
#
#   Legacy single-account install (unchanged):
#     powershell -ExecutionPolicy Bypass -File uninstall-backup-agent.ps1
#
#   One account of a -PerAccount install:
#     powershell -ExecutionPolicy Bypass -File uninstall-backup-agent.ps1 -Account Acc2
#
# Does, in order:
#   1. Stops + unregisters that account's Scheduled Task
#   2. Stops only that account's running watcher process
#   3. If no backup tasks remain, deletes the shared machine env keys
#      and the shared restic password file
#
# Optional: -Full also removes this account's deployed watcher/config/logs.
# restic.exe and the shared password are only removed when no other backup
# task is left, so uninstalling Acc2 never breaks Acc1.
# =====================================================================

param(
    # Per-account mode: account name (e.g. Acc2). Derives task name and
    # config dir. Ignored when -TaskName/-ConfigDir are supplied.
    [string]$Account = "",

    [string]$TaskName = "",
    [string]$ConfigDir = "",

    [switch]$Full
)

$ErrorActionPreference = "Continue"
$PSNativeCommandUseErrorActionPreference = $false

$BaseConfigDir = "$env:ProgramData\DocBackup"

function Get-SafeAccount {
    param([string]$Name)
    return (($Name -split '\\')[-1] -replace '[^A-Za-z0-9._-]', '-').Trim('-')
}

if ($Account) {
    $SafeAccount = Get-SafeAccount -Name $Account
    if (-not $TaskName)   { $TaskName   = "DocumentsBackupSync-$SafeAccount" }
    if (-not $ConfigDir)  { $ConfigDir  = Join-Path (Join-Path $BaseConfigDir "Accounts") $SafeAccount }
} else {
    if (-not $TaskName)   { $TaskName   = "DocumentsBackupSync" }
    if (-not $ConfigDir)  { $ConfigDir  = $BaseConfigDir }
}

$PasswordFile = Join-Path $BaseConfigDir "restic-password.txt"
$ScriptDest   = Join-Path $ConfigDir "sync-documents.ps1"
$EnvVars      = @("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "RESTIC_REPOSITORY", "RESTIC_PASSWORD_FILE")

# ---- Re-launch elevated if not already admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    $fwdArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Account) { $fwdArgs += " -Account `"$Account`"" }
    elseif ($TaskName -ne "DocumentsBackupSync") { $fwdArgs += " -TaskName `"$TaskName`"" }
    if (-not $Account -and $ConfigDir -ne $BaseConfigDir) { $fwdArgs += " -ConfigDir `"$ConfigDir`"" }
    if ($Full) { $fwdArgs += " -Full" }
    Start-Process powershell -Verb RunAs -ArgumentList $fwdArgs
    exit
}

Write-Host ""
Write-Host "=== Uninstalling Documents Backup Agent ==="
Write-Host "Task:       $TaskName"
Write-Host "Config dir: $ConfigDir"
Write-Host ""

# ---- 1. Stop + unregister the Scheduled Task ----
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Scheduled task '$TaskName' stopped."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop | Out-Null
    Write-Host "Scheduled task '$TaskName' removed."
} else {
    Write-Host "Scheduled task '$TaskName' not found, skipping."
}

# ---- 2. Stop only this agent's watcher process ----
# The FileSystemWatchers live inside powershell.exe processes, so killing the
# one whose command line contains THIS config dir's script path is what
# actually stops the watchers. Legacy and per-account script paths do not
# contain each other, so this never touches another account's agent.
# Exclude this uninstall script's own process.
$myPid = $PID
$stopped = 0
try {
    $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -like "*$ScriptDest*" -and $_.ProcessId -ne $myPid
        }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped watcher process (PID $($p.ProcessId))."
            $stopped++
        } catch {
            Write-Host "Could not stop PID $($p.ProcessId): $_"
        }
    }
} catch {
    Write-Host "Watcher process lookup skipped: $_"
}
if ($stopped -eq 0) { Write-Host "No running watcher process found for this agent." }

# ---- 3. Shared secrets: remove only when no backup task remains ----
$remainingTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -like 'DocumentsBackupSync*' })

if ($remainingTasks.Count -eq 0) {
    foreach ($v in $EnvVars) {
        try {
            [Environment]::SetEnvironmentVariable($v, $null, "Machine")
            [Environment]::SetEnvironmentVariable($v, $null, "Process")
            Write-Host "Env var removed (Machine + Process): $v"
        } catch {
            Write-Host "Could not remove env var ${v}: $_"
        }
    }

    if (Test-Path -LiteralPath $PasswordFile) {
        # The file is ACL'd read-only for SYSTEM/Administrators/task users
        # with inheritance disabled, so take rights back before deleting.
        # SIDs, not localised group names.
        & icacls $PasswordFile /reset 2>$null | Out-Null
        & icacls $PasswordFile /grant:r "*S-1-5-32-544:(F)" "*S-1-5-18:(F)" 2>$null | Out-Null
        try {
            Remove-Item -Path $PasswordFile -Force -ErrorAction Stop
            Write-Host "Password file deleted: $PasswordFile"
        } catch {
            Write-Host "Could not delete password file ${PasswordFile}: $_"
        }
    }
} else {
    Write-Host "Shared credentials kept: $($remainingTasks.Count) other backup task(s) still configured."
}

# ---- Optional: full cleanup for THIS agent ----
if ($Full) {
    Write-Host ""
    Write-Host "--- Full cleanup (-Full) ---"
    $filesToRemove = @(
        (Join-Path $ConfigDir "sync-documents.ps1"),
        (Join-Path $ConfigDir "excludes.txt"),
        (Join-Path $ConfigDir "extra-paths.txt"),
        (Join-Path $ConfigDir "retention.json"),
        (Join-Path $ConfigDir "backup-config.json"),
        (Join-Path $ConfigDir "last-prune.txt"),
        (Join-Path $ConfigDir "sync.log"),
        (Join-Path $ConfigDir "sync.log.1")
    )
    foreach ($f in $filesToRemove) {
        if (Test-Path $f) {
            try { Remove-Item -Path $f -Force -ErrorAction Stop; Write-Host "Deleted: $f" }
            catch { Write-Host "Could not delete ${f}: $_" }
        }
    }

    # restic.exe and the machine PATH entry are shared by every agent on the
    # machine, so only remove them when no backup task remains.
    if ($remainingTasks.Count -eq 0) {
        $ProgramFilesDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
            Where-Object { $_ } | Select-Object -Unique
        foreach ($pf in $ProgramFilesDirs) {
            $installDir = Join-Path $pf "restic"
            $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($machinePath -like "*$installDir*") {
                $newPath = ($machinePath -split ";" | Where-Object { $_ -and $_ -ne $installDir }) -join ";"
                [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
                Write-Host "Removed $installDir from machine PATH."
            }
            if (Test-Path $installDir) {
                try { Remove-Item -Path $installDir -Recurse -Force -ErrorAction Stop; Write-Host "Deleted: $installDir" }
                catch { Write-Host "Could not delete ${installDir}: $_" }
            }
        }
    } else {
        Write-Host "restic kept: other backup task(s) still configured."
    }

    # Remove this account's now-empty config dir. The base dir is kept while
    # any per-account dirs or shared files remain.
    if ((Test-Path $ConfigDir) -and -not (Get-ChildItem -Path $ConfigDir -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -Path $ConfigDir -Force -ErrorAction Stop; Write-Host "Deleted empty dir: $ConfigDir" }
        catch { Write-Host "Could not delete ${ConfigDir}: $_" }
    } elseif (Test-Path $ConfigDir) {
        Write-Host "Config dir kept (still contains files): $ConfigDir"
    }
    $accountsDir = Join-Path $BaseConfigDir "Accounts"
    if ((Test-Path $accountsDir) -and -not (Get-ChildItem -Path $accountsDir -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -Path $accountsDir -Force -ErrorAction Stop; Write-Host "Deleted empty dir: $accountsDir" }
        catch { Write-Host "Could not delete ${accountsDir}: $_" }
    }
}

Write-Host ""
Write-Host "=== Uninstall complete ==="
Write-Host "Removed task '$TaskName' and this agent's watcher process."
if ($remainingTasks.Count -eq 0) {
    Write-Host "Removed shared env keys and $PasswordFile (no backup tasks remain)."
} else {
    Write-Host "Kept shared env keys and $PasswordFile ($($remainingTasks.Count) backup task(s) remain)."
}
if (-not $Full) {
    Write-Host "Kept: restic.exe, logs, excludes (re-run with -Full to remove this agent's files too)"
}
Write-Host "========================= End of uninstall-backup-agent ============================"
