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
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [string]$WasabiEndpoint = "https://s3.eu-south-1.wasabisys.com",
    [string]$BucketAndPrefix = "ssrms-bucket",
    [string]$RestoreRoot = "C:\RestoreTests"
)

$ErrorActionPreference = "Stop"
# See install-backup-agent.ps1 for why this is needed on PowerShell 7.3+:
# native command non-zero exits would otherwise throw and bypass the
# $LASTEXITCODE checks this script relies on (e.g. restic check / restore
# failures). Harmless no-op on 5.1.
$PSNativeCommandUseErrorActionPreference = $false
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
    $latest = $snapshotOutput | ConvertFrom-Json
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
& restic restore $snapshotId --target $restoreDir 2>&1 | Add-Content -Path $logFile
if ($LASTEXITCODE -ne 0) {
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