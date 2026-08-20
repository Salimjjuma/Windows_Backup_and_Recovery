# =====================================================================
# sync-documents.ps1  (restic edition)
# Continuously backs up the current user's Documents folder to a
# per-laptop restic repository on Wasabi S3. Triggered on file change
# (debounced) + a periodic failsafe backup + weekly retention pruning.
# Intended to run under a Scheduled Task at logon.
#
# Assumes the following machine-level environment variables are
# already set by install-backup-agent.ps1:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, RESTIC_REPOSITORY,
#   RESTIC_PASSWORD_FILE
# =====================================================================

$ErrorActionPreference = "Stop"

# ---- Config ----
$SourcePath     = [Environment]::GetFolderPath("MyDocuments")
$HostName       = $env:COMPUTERNAME
$LogDir         = "$env:ProgramData\DocBackup\"
$LogFile        = Join-Path $LogDir "sync.log"
$DebounceSec    = 30      # wait this long after last change before backing up
$FailsafeMin    = 15      # always do a full backup at least this often
$PruneHours     = 168     # run retention pruning at least this often (weekly)

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogFile -Value $line
}

function Invoke-Backup {
    param([string]$Reason)
    Write-Log "Backup starting ($Reason)"
    $resticArgs = @(
        "backup", $SourcePath,
        "--tag", $HostName,
        "--exclude", "*.tmp",
        "--exclude", "~$*",              # skip Office lock files
        "--exclude", "desktop.ini"
    )
    try {
        $output = & restic @resticArgs 2>&1
        $output | Add-Content -Path $LogFile
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Backup completed successfully ($Reason)"
        } else {
            Write-Log "Backup FAILED with exit code $LASTEXITCODE ($Reason)"
        }
    } catch {
        Write-Log "Backup ERROR: $_"
    }
}

function Invoke-Prune {
    Write-Log "Retention pruning starting"
    $forgetArgs = @(
        "forget",
        "--tag", $HostName,
        "--keep-daily", "14",
        "--keep-weekly", "8",
        "--keep-monthly", "12",
        "--prune"
    )
    try {
        $output = & restic @forgetArgs 2>&1
        $output | Add-Content -Path $LogFile
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Retention pruning completed successfully"
        } else {
            Write-Log "Retention pruning FAILED with exit code $LASTEXITCODE"
        }
    } catch {
        Write-Log "Retention pruning ERROR: $_"
    }
}

Write-Log "=== sync-documents (restic) starting for $HostName, source=$SourcePath ==="
Write-Log "Repository: $env:RESTIC_REPOSITORY"

# Initial backup on startup
Invoke-Backup -Reason "startup"

# ---- File watcher with debounce ----
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $SourcePath
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor `
                        [System.IO.NotifyFilters]::FileName -bor `
                        [System.IO.NotifyFilters]::DirectoryName

$debounceTimer = New-Object System.Timers.Timer
$debounceTimer.Interval = $DebounceSec * 1000
$debounceTimer.AutoReset = $false

Register-ObjectEvent -InputObject $debounceTimer -EventName Elapsed -Action {
    Invoke-Backup -Reason "file change"
} | Out-Null

$onChange = {
    $debounceTimer.Stop()
    $debounceTimer.Start()
}

Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $onChange | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Created -Action $onChange | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $onChange | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $onChange | Out-Null

Write-Log "Watcher active on $SourcePath"

# ---- Periodic failsafe backup (covers sleep/hibernate, missed events) ----
$failsafeTimer = New-Object System.Timers.Timer
$failsafeTimer.Interval = $FailsafeMin * 60 * 1000
$failsafeTimer.AutoReset = $true
Register-ObjectEvent -InputObject $failsafeTimer -EventName Elapsed -Action {
    Invoke-Backup -Reason "failsafe periodic"
} | Out-Null
$failsafeTimer.Start()

# ---- Periodic retention pruning ----
$pruneTimer = New-Object System.Timers.Timer
$pruneTimer.Interval = $PruneHours * 60 * 60 * 1000
$pruneTimer.AutoReset = $true
Register-ObjectEvent -InputObject $pruneTimer -EventName Elapsed -Action {
    Invoke-Prune
} | Out-Null
$pruneTimer.Start()

# Keep the script alive indefinitely, processing events
while ($true) {
    Wait-Event -Timeout 60 | Out-Null
}
