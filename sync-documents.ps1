# =====================================================================
# sync-documents.ps1  (restic edition)
# Continuously backs up the current user's Documents, Desktop, and
# Downloads folders to a per-laptop restic repository on Wasabi S3.
# Triggered on file change (debounced) + a periodic failsafe backup +
# weekly retention pruning. Intended to run under a Scheduled Task at logon.
#
# Assumes the following machine-level environment variables are
# already set by install-backup-agent.ps1:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, RESTIC_REPOSITORY,
#   RESTIC_PASSWORD_FILE
# =====================================================================

$ErrorActionPreference = "Stop"

# ---- Hide this script's own console window ----
# The scheduled task already passes -WindowStyle Hidden, but that flag is
# not reliably honored on all Windows builds (notably when Windows
# Terminal is the default console host) - a visible, empty window can be
# left open indefinitely since this script runs forever by design. Hiding
# the window directly via the Win32 API is reliable regardless of host.
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[Console.Window]::ShowWindow($consolePtr, 0) | Out-Null   # 0 = SW_HIDE

# ---- Config ----
# Get the Downloads folder path (not exposed via GetFolderPath, needs the known-folder GUID)
# function Get-DownloadsFolder {
#     $shell = New-Object -ComObject Shell.Application
#     $folder = $shell.Namespace('shell:Downloads').Self.Path
#     return $folder
# }

$SourcePaths = @(
    [Environment]::GetFolderPath("MyDocuments"),
    [Environment]::GetFolderPath("Desktop")
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

$HostName       = $env:COMPUTERNAME
$LogDir         = "$env:ProgramData\DocBackup"
$LogFile        = Join-Path $LogDir "sync.log"
$ExcludeFile    = Join-Path $LogDir "excludes.txt"
$DebounceSec    = 30      # wait this long after last change before backing up
$FailsafeMin    = 15      # always do a full backup at least this often
$PruneHours     = 168     # run retention pruning at least this often (weekly)
$MaxFileSizeMB  = 500     # skip individual files larger than this (installers, ISOs, VM images, etc.)

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Prevents overlapping restic invocations: if a change-triggered backup,
# the failsafe timer, and a manual trigger all fire close together, only
# one restic process runs at a time. Without this, a slow first backup
# can still be running when the next trigger fires, causing lock
# contention (and making everything slower, not faster).
$script:BackupRunning = $false

# Create a default excludes file on first run if none exists.
# IT staff can edit this file directly on any laptop (or push an updated
# version) without touching this script.
if (-not (Test-Path $ExcludeFile)) {
    @'
# restic exclude patterns - one glob pattern per line, # for comments
# Temp / lock files
*.tmp
~$*
desktop.ini
# Media files excluded from backup per IT policy
*.mp4
*.mp3
*.jpeg
*.jpg
*.png
'@ | Set-Content -Path $ExcludeFile
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogFile -Value $line
}

function Invoke-Backup {
    param([string]$Reason)

    if ($script:BackupRunning) {
        Write-Log "Backup SKIPPED ($Reason) - a backup is already in progress"
        return
    }
    $script:BackupRunning = $true

    Write-Log "Backup starting ($Reason) - paths: $($SourcePaths -join ', ')"
    $resticArgs = @("backup") + $SourcePaths + @(
        "--tag", $HostName,
        "--exclude-file", $ExcludeFile,
        "--exclude-larger-than", "${MaxFileSizeMB}M",
        "--skip-if-unchanged",
        "--json"
    )
    # This runs hidden/non-interactively (no console), so a visual progress
    # bar has nowhere to render. Instead, restic's --json stream is parsed
    # and a checkpoint is logged every time progress crosses a new 10%
    # threshold, so sync.log shows how far a long backup has gotten rather
    # than just a start line and, eventually, a finish line.
    $lastLoggedDecile = -1
    try {
        & restic @resticArgs 2>&1 | ForEach-Object {
            $line = $_
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                Add-Content -Path $LogFile -Value "restic: $line"
                return
            }
            try {
                $evt = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Add-Content -Path $LogFile -Value $line
                return
            }
            switch ($evt.message_type) {
                "status" {
                    $pct = [math]::Round($evt.percent_done * 100)
                    $decile = [math]::Floor($pct / 10)
                    if ($decile -ne $lastLoggedDecile) {
                        $lastLoggedDecile = $decile
                        $doneGB = [math]::Round($evt.bytes_done / 1GB, 2)
                        $totalGB = [math]::Round($evt.total_bytes / 1GB, 2)
                        Write-Log "Backup progress: $pct% ($($evt.files_done)/$($evt.total_files) files, ${doneGB}GB/${totalGB}GB)"
                    }
                }
                "summary" {
                    if ($evt.snapshot_id) {
                        $addedMB = [math]::Round($evt.data_added / 1MB, 1)
                        Write-Log "Backup summary: snapshot $($evt.snapshot_id), $($evt.total_files_processed) files processed, ${addedMB}MB new data, $([math]::Round($evt.total_duration,1))s"
                    } else {
                        Write-Log "Backup summary: no changes since last snapshot, skipped (--skip-if-unchanged)"
                    }
                }
                default {
                    Add-Content -Path $LogFile -Value $line
                }
            }
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Backup completed successfully ($Reason)"
        } else {
            Write-Log "Backup FAILED with exit code $LASTEXITCODE ($Reason)"
        }
    } catch {
        Write-Log "Backup ERROR: $_"
    } finally {
        $script:BackupRunning = $false
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

Write-Log "=== sync-documents (restic) starting for $HostName ==="
Write-Log "Watched paths: $($SourcePaths -join ', ')"
Write-Log "Exclude file: $ExcludeFile"
Write-Log "Max file size: ${MaxFileSizeMB}MB"
Write-Log "Repository: $env:RESTIC_REPOSITORY"

# Clear any stale lock left behind by an unclean shutdown (sleep, crash,
# forced logoff) during a previous backup. Safe here specifically because
# only one instance of this agent runs per laptop (single scheduled
# task) - so at a fresh script start, any existing lock cannot belong to
# a still-running process from this laptop. If someone is separately
# running restic manually against this same repository at this exact
# moment, this could clear their lock too - an accepted low-probability
# tradeoff for a system that must otherwise self-recover unattended.
Write-Log "Checking for stale locks..."
$unlockOutput = & restic unlock 2>&1
$unlockOutput | Add-Content -Path $LogFile

# Initial backup on startup
Invoke-Backup -Reason "startup"

# ---- File watchers with shared debounce ----
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

$watchers = @()
foreach ($path in $SourcePaths) {
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $path
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor `
                            [System.IO.NotifyFilters]::FileName -bor `
                            [System.IO.NotifyFilters]::DirectoryName

    Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $onChange | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Created -Action $onChange | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $onChange | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $onChange | Out-Null

    $watchers += $watcher
    Write-Log "Watcher active on $path"
}

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