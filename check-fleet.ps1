# =====================================================================
# check-fleet.ps1
# Run by IT (not on staff laptops) to check every laptop's restic
# repository: snapshot count, latest snapshot time, and repo size.
#
# Usage:
#   powershell -File check-fleet.ps1 -HostNames LAPTOP-1,LAPTOP-2
#   powershell -File check-fleet.ps1   # discover via AWS CLI if present
#
# Requires AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / RESTIC_PASSWORD_FILE
# already set in IT's own environment (same as test-restore.ps1).
# =====================================================================

param(
    [string[]]$HostNames = @(),

    [string]$WasabiEndpoint = "https://s3.eu-south-1.wasabisys.com",
    [string]$BucketAndPrefix = "mewabackup"
)

$ErrorActionPreference = "Continue"
# NOT "Stop": this script runs restic.exe per laptop and checks
# $LASTEXITCODE explicitly. With ErrorActionPreference = "Stop", any text
# restic writes to stderr gets converted into a terminating exception,
# bypassing those checks.
$PSNativeCommandUseErrorActionPreference = $false

# ---- Preflight ----
# Drop blank entries so -HostNames "",("PC-1","") etc. fall through to
# discovery (or the empty-repo error) instead of querying a garbage path.
$HostNames = @($HostNames | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
foreach ($v in @("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "RESTIC_PASSWORD_FILE")) {
    if (-not [Environment]::GetEnvironmentVariable($v)) {
        Write-Warning "$v is not set in this session - restic calls will likely fail."
    }
}
$resticCmd = Get-Command restic -ErrorAction SilentlyContinue
if (-not $resticCmd) { throw "restic not found in PATH on this machine." }

$Bucket = ($BucketAndPrefix -split "/")[0]
$SavedRepo = $env:RESTIC_REPOSITORY

# ---- Discover laptop prefixes if none were passed ----
if (-not $HostNames -or $HostNames.Count -eq 0) {
    $awsCmd = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $awsCmd) {
        throw "No -HostNames given and AWS CLI not found. Pass -HostNames explicitly, e.g.: check-fleet.ps1 -HostNames LAPTOP-1,LAPTOP-2"
    }
    Write-Host "Discovering repositories in s3://$BucketAndPrefix via AWS CLI..."
    # Each laptop repo is a prefix containing a restic 'config' file, so the
    # top-level key prefixes under the bucket are the host names.
    $prefixesJson = & aws s3api list-objects-v2 --bucket $Bucket --delimiter "/" `
        --endpoint-url $WasabiEndpoint --query "CommonPrefixes[].Prefix" --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Bucket listing failed: $prefixesJson"
    }
    try {
        $prefixes = ($prefixesJson | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json
    } catch {
        throw "Could not parse bucket listing as JSON: $prefixesJson"
    }
    $HostNames = @($prefixes | ForEach-Object { $_.TrimEnd("/") } | Where-Object { $_ })
    if (-not $HostNames -or $HostNames.Count -eq 0) {
        throw "No repository prefixes found under s3://$BucketAndPrefix."
    }
    Write-Host "Found $($HostNames.Count) repositorie(s): $($HostNames -join ', ')"
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

$results = @()
$failCount = 0
$i = 0
foreach ($HostName in $HostNames) {
    $i++
    $pct = [math]::Round($i / $HostNames.Count * 100)
    Write-Progress -Activity "Checking fleet repositories ($BucketAndPrefix)" `
        -Status "Laptop $i of $($HostNames.Count) - $HostName" -PercentComplete $pct

    $env:RESTIC_REPOSITORY = "s3:$WasabiEndpoint/$BucketAndPrefix/$HostName"
    $row = [PSCustomObject]@{
        Name      = $HostName
        Status    = ""
        Snapshots = 0
        Latest    = ""
        Size      = ""
    }

    # ---- Snapshots (count + latest time) ----
    $snapJson = & restic snapshots --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $row.Status = "FAIL snapshots"
        $failCount++
        $results += $row
        Write-Warning "$HostName : could not list snapshots (${snapJson} | head -1)"
        continue
    }
    try {
        # 2>&1 above can mix stderr ErrorRecords in - keep stdout JSON only.
        $snapLines = @($snapJson | Where-Object { $_ -is [string] })
        $snaps = @($snapLines -join "`n" | ConvertFrom-Json)
    } catch {
        $row.Status = "FAIL parse"
        $failCount++
        $results += $row
        Write-Warning "$HostName : snapshot output was not valid JSON."
        continue
    }
    $row.Snapshots = $snaps.Count
    if ($snaps.Count -gt 0) {
        $latest = $snaps | Sort-Object { $_.time } | Select-Object -Last 1
        $row.Latest = $latest.time
    }

    # ---- Repo size (raw data on disk) ----
    $statsJson = & restic stats --mode raw-data --json 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $statLines = @($statsJson | Where-Object { $_ -is [string] })
            $stats = $statLines -join "`n" | ConvertFrom-Json
            $row.Size = Format-Bytes -Bytes ([long]$stats.total_size)
        } catch {
            $row.Size = "unknown"
        }
    } else {
        $row.Size = "unknown"
    }

    if ($row.Snapshots -eq 0) {
        $row.Status = "FAIL empty"
        $failCount++
    } else {
        $row.Status = "OK"
    }
    $results += $row
}
Write-Progress -Activity "Checking fleet repositories ($BucketAndPrefix)" -Completed

$env:RESTIC_REPOSITORY = $SavedRepo

$results | Format-Table -AutoSize Name, Status, Snapshots, Latest, Size | Out-String | Write-Host
Write-Host "Checked $($HostNames.Count) laptop(s): $($HostNames.Count - $failCount) OK, $failCount FAIL."

if ($failCount -gt 0) { exit 1 }
