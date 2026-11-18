# =====================================================================
# check-fleet.ps1
# Run by IT (not on staff laptops) to check every laptop's restic
# repository: snapshot count, latest snapshot time, repo size, and prune
# backlog (snapshots the retention policy — read from retention.json — would
# still remove: a sign pruning is behind, e.g. after agent restarts).
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

# ---- Retention policy (single source of truth: retention.json) ----
# Shared with sync-documents.ps1 (the agent), check-fleet.sh and
# fleet-dashboard.py, so the prune backlog column always reflects the policy
# the laptops actually prune with. Defaults match the old hard-coded values.
$RetentionFile = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot "retention.json"
} else {
    # e.g. pasted into ISE, where $PSScriptRoot is empty
    Join-Path (Get-Location).Path "retention.json"
}
$KeepDaily = 14; $KeepWeekly = 8; $KeepMonthly = 12

function Read-KeepCount {
    param($Config, [string]$Name, [int]$Default)
    if ($null -eq $Config) { return $Default }
    $raw = $Config.$Name
    if ($null -eq $raw) { return $Default }
    $parsed = 0
    if ([int]::TryParse("$raw", [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}

try {
    if (Test-Path $RetentionFile) {
        $retentionConfig = Get-Content -Path $RetentionFile -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        $KeepDaily   = Read-KeepCount -Config $retentionConfig -Name "keepDaily"   -Default $KeepDaily
        $KeepWeekly  = Read-KeepCount -Config $retentionConfig -Name "keepWeekly"  -Default $KeepWeekly
        $KeepMonthly = Read-KeepCount -Config $retentionConfig -Name "keepMonthly" -Default $KeepMonthly
    }
} catch {
    Write-Warning "Could not read $RetentionFile - using defaults ($KeepDaily/$KeepWeekly/$KeepMonthly)."
}
Write-Host "Retention policy: keep-daily $KeepDaily, keep-weekly $KeepWeekly, keep-monthly $KeepMonthly"

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

# Retention policy mirrors the agent's restic forget --prune run, read from
# retention.json (shared with sync-documents.ps1, check-fleet.sh and
# fleet-dashboard.py). Re-evaluating it against the repo's snapshot list
# approximates what a pending forget run would still remove: >0 means pruning
# is behind (e.g. the agent's weekly schedule drifted after restarts).
# Snapshots are bucketed in UTC, and a snapshot kept for any one criterion
# (N distinct days, N distinct ISO weeks, N distinct months, newest always)
# counts as kept - the same union restic's policy applies.
function Get-PruneBacklog {
    param([object[]]$Snaps)
    $times = @()
    foreach ($s in $Snaps) {
        if (-not $s -or -not $s.time) { continue }
        try { $dt = [datetime]$s.time } catch { continue }
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
        }
        $times += $dt
    }
    if ($times.Count -eq 0) { return @{ Count = -1; OldestDays = $null } }

    # ISO 8601 snapshot times parse as Local/UTC via [datetime] casts; work
    # in one common frame: convert everything to UTC for bucketing AND ages.
    $utcTimes = @($times | ForEach-Object { $_.ToUniversalTime() })
    $sorted = @($utcTimes | Sort-Object { $_ } -Descending:$true)

    $KD = $script:KeepDaily; $KW = $script:KeepWeekly; $KM = $script:KeepMonthly
    $seenDaily = New-Object "System.Collections.Generic.HashSet[string]"
    $seenWeekly = New-Object "System.Collections.Generic.HashSet[string]"
    $seenMonthly = New-Object "System.Collections.Generic.HashSet[string]"
    $dailyUsed = 0; $weeklyUsed = 0; $monthlyUsed = 0
    $removable = @()
    $now = [datetime]::UtcNow
    foreach ($t in $sorted) {
        $keep = $false
        $kb = $t.ToString("yyyy-MM-dd")
        if (-not $seenDaily.Contains($kb) -and $dailyUsed -lt $KD) {
            [void]$seenDaily.Add($kb); $dailyUsed++; $keep = $true
        }
        # ISO-8601 week and ISO week-year (Monday-based; week 1 is the week
        # containing the first Thursday), matching Python's isocalendar() in
        # check-fleet.sh and the dashboard - including across New Year, where
        # the old InvariantCulture GetWeekOfYear could disagree by one week.
        # .NET Framework (PowerShell 5.1) has no ISOWeek class, hence manual.
        $thursday = $t.Date.AddDays(3 - (([int]$t.DayOfWeek + 6) % 7))
        $wb = "$($thursday.Year)-W$([int][math]::Floor(($thursday.DayOfYear - 1) / 7) + 1)"
        if (-not $seenWeekly.Contains($wb) -and $weeklyUsed -lt $KW) {
            [void]$seenWeekly.Add($wb); $weeklyUsed++; $keep = $true
        }
        $mb = $t.ToString("yyyy-MM")
        if (-not $seenMonthly.Contains($mb) -and $monthlyUsed -lt $KM) {
            [void]$seenMonthly.Add($mb); $monthlyUsed++; $keep = $true
        }
        if (-not $keep) { $removable += $t }
    }
    if ($removable.Count -eq 0) { return @{ Count = 0; OldestDays = $null } }
    $oldest = [math]::Round(($now - ($removable | Measure-Object -Minimum).Minimum).TotalDays)
    return @{ Count = $removable.Count; OldestDays = [int]$oldest }
}

function Format-PruneBacklog {
    param($Info)
    if ($null -eq $Info -or $Info.Count -lt 0) { return "unknown" }
    if ($Info.Count -eq 0) { return "none pending" }
    return "$($Info.Count) snaps ($($Info.OldestDays)d)"
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
        Prune     = "unknown"
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
    $row.Prune = Format-PruneBacklog (Get-PruneBacklog $snaps)

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

$results | Format-Table -AutoSize Name, Status, Snapshots, Latest, Size, Prune | Out-String | Write-Host
Write-Host "Checked $($HostNames.Count) laptop(s): $($HostNames.Count - $failCount) OK, $failCount FAIL."

if ($failCount -gt 0) { exit 1 }
