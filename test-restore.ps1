# =====================================================================
# test-restore.ps1
# Run by IT (not on staff laptops) to perform scheduled restoration
# and integrity testing per the Backup and Recovery Policy, section 5.
#
# Usage:
#   powershell -File test-restore.ps1 -HostName LAPTOP-JSMITH
#
# Requires the same env vars as the laptops for repository access,
# but pointed at ONE laptop's repository at a time via -HostName.
# =====================================================================

param(
    # Repository prefix to test. Legacy laptops: COMPUTERNAME.
    # Per-account laptops: COMPUTERNAME-<account> (e.g. LAPTOP-JSMITH-Acc2).
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    # Empty = read from backup-config.json next to this script, then the
    # built-in default.
    [string]$WasabiEndpoint = "",
    [string]$BucketAndPrefix = "",
    [string]$RestoreRoot = "C:\RestoreTests"
)

$ErrorActionPreference = "Continue"
# NOT "Stop": this script repeatedly runs restic.exe (check, snapshots,
# restore) and checks $LASTEXITCODE explicitly. With
# ErrorActionPreference = "Stop", any text restic writes to stderr gets
# converted into a terminating exception, bypassing those checks -
# including cases where restic's own diagnostic output is expected, not
# a real failure.
$PSNativeCommandUseErrorActionPreference = $false

# ---- Shared endpoint/bucket (backup-config.json) ----
function Read-BackupConfig {
    $candidates = @()
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot "backup-config.json") }
    $candidates += (Join-Path (Get-Location).Path "backup-config.json")
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) {
            try { return Get-Content -Path $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
            catch { Write-Warning "Could not read ${p}: $($_.Exception.Message)" }
        }
    }
    return $null
}
$BackupConfig = Read-BackupConfig
if (-not $WasabiEndpoint) {
    $WasabiEndpoint = if ($BackupConfig -and $BackupConfig.wasabiEndpoint) {
        "$($BackupConfig.wasabiEndpoint)"
    } else {
        "https://s3.eu-south-1.wasabisys.com"
    }
}
if (-not $BucketAndPrefix) {
    $BucketAndPrefix = if ($BackupConfig -and $BackupConfig.bucketAndPrefix) {
        "$($BackupConfig.bucketAndPrefix)"
    } else {
        "mewabackup"
    }
}

$WasabiEndpoint = "$WasabiEndpoint".Trim().TrimEnd('/')
$BucketAndPrefix = "$BucketAndPrefix".Trim().TrimEnd('/')
if (-not $WasabiEndpoint -or -not $BucketAndPrefix) {
    throw "Wasabi endpoint and bucket must not be empty."
}
if ($BucketAndPrefix -match '/') {
    throw "bucketAndPrefix must be a bucket name only (found '$BucketAndPrefix'). The fleet tools discover repositories as top-level prefixes inside the bucket."
}

$env:RESTIC_REPOSITORY = "s3:$WasabiEndpoint/$BucketAndPrefix/$HostName"
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / RESTIC_PASSWORD_FILE
# are expected to already be set in IT's own environment.

$stamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
$restoreDir = Join-Path $RestoreRoot "$HostName-$stamp"
$logFile = Join-Path $RestoreRoot "restore-test-log.txt"

New-Item -ItemType Directory -Force -Path $RestoreRoot | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

# This script runs interactively (an IT admin runs it directly), so unlike
# the laptop-side background agent, a real progress bar makes sense here.
# Parses restic's --json event stream and drives Write-Progress from it;
# also logs a text checkpoint every 10% for the log file record.
function Invoke-ResticWithProgress {
    param(
        [string[]]$ResticArgs,
        [string]$Activity
    )
    $fullArgs = $ResticArgs + @("--json")
    $lastPercent = -1
    $lastLoggedDecile = -1
    & restic @fullArgs 2>&1 | ForEach-Object {
        $line = $_
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            Write-Host $line -ForegroundColor Yellow
            Add-Content -Path $logFile -Value "restic: $line"
            return
        }
        try {
            $evt = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Host $line
            Add-Content -Path $logFile -Value $line
            return
        }
        if ($evt.message_type -eq "status") {
            $pct = [math]::Round($evt.percent_done * 100)
            if ($pct -ne $lastPercent) {
                $lastPercent = $pct
                $filesInfo = if ($evt.total_files) { "$($evt.files_done)/$($evt.total_files) files" }
                             elseif ($evt.total_bytes) { "$($evt.bytes_restored)/$($evt.total_bytes) bytes" }
                             else { "" }
                Write-Progress -Activity $Activity -Status "$pct% complete - $filesInfo" -PercentComplete $pct
            }
            $decile = [math]::Floor($pct / 10)
            if ($decile -ne $lastLoggedDecile) {
                $lastLoggedDecile = $decile
                Write-Log "$Activity progress: $pct%"
            }
        } elseif ($evt.message_type -eq "summary") {
            Write-Progress -Activity $Activity -Completed
        } elseif ($evt.message_type -eq "error") {
            Write-Host "restic error: $($evt.error.message) (item: $($evt.item))" -ForegroundColor Red
            Add-Content -Path $logFile -Value "restic error: $($evt.error.message) (item: $($evt.item))"
        }
    }
    Write-Progress -Activity $Activity -Completed
    return $LASTEXITCODE
}

Write-Log "=== Restoration test starting for $HostName ==="
Write-Log "Repository: $env:RESTIC_REPOSITORY"

# ---- 1. Repository integrity check (verifies encryption/auth structures are intact) ----
Write-Log "Running restic check..."
& restic check 2>&1 | Tee-Object -Variable checkOutput | Out-Null
$checkOutput | Add-Content -Path $logFile
if ($LASTEXITCODE -ne 0) {
    Write-Log "RESULT: FAIL - restic check reported errors for $HostName's repository"
    exit 1
}
Write-Log "restic check passed."

# ---- 2. Pick the latest snapshot ----
Write-Log "Querying snapshots..."
$snapshotOutput = & restic snapshots --latest 1 --json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "RESULT: FAIL - could not query snapshots for $HostName (restic command failed, not necessarily an empty repository)"
    Write-Log "restic output: $snapshotOutput"
    Write-Log "Check: repository path is correct (RESTIC_REPOSITORY=$env:RESTIC_REPOSITORY), credentials/RESTIC_PASSWORD_FILE are set correctly in this session, and network access to the endpoint."
    exit 1
}

try {
    # 2>&1 above can mix stderr ErrorRecords in - keep stdout JSON only, and
    # join the lines so ConvertFrom-Json sees one complete document
    # (same guard as check-fleet.ps1).
    $snapLines = @($snapshotOutput | Where-Object { $_ -is [string] })
    $latest = @($snapLines -join "`n" | ConvertFrom-Json)
} catch {
    Write-Log "RESULT: FAIL - restic command succeeded but output could not be parsed as JSON for $HostName"
    Write-Log "restic output: $snapshotOutput"
    exit 1
}

if (-not $latest -or $latest.Count -eq 0) {
    Write-Log "RESULT: FAIL - repository reachable but genuinely contains no snapshots for $HostName"
    exit 1
}
$snapshotId = $latest[0].short_id
Write-Log "Restoring latest snapshot $snapshotId to $restoreDir"

# ---- 3. Restore into an isolated folder ----
# Uses the --json streaming helper so the interactive run gets a live
# progress bar (long restores otherwise look hung), and the log gets
# 10% checkpoints instead of pages of raw JSON progress lines.
$restoreRc = Invoke-ResticWithProgress -ResticArgs @("restore", $snapshotId, "--target", $restoreDir) -Activity "Restoring snapshot $snapshotId"
if ($restoreRc -ne 0) {
    Write-Log "RESULT: FAIL - restic restore failed for snapshot $snapshotId"
    exit 1
}

# ---- 4. Sanity check restored data ----
$restoredFiles = Get-ChildItem -Path $restoreDir -Recurse -File -ErrorAction SilentlyContinue
$fileCount = ($restoredFiles | Measure-Object).Count

if ($fileCount -eq 0) {
    Write-Log "RESULT: FAIL - restore produced 0 files, snapshot may be empty or corrupt"
    exit 1
}

Write-Log "RESULT: PASS - restored $fileCount file(s) successfully from snapshot $snapshotId"

# ---- 5. Clean up the restored test data (keep only the log) ----
Remove-Item -Path $restoreDir -Recurse -Force

Write-Log "=== Restoration test complete for $HostName ==="