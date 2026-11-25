# =====================================================================
# verify-backup-agent.ps1
# READ-ONLY health check for installed backup agents.
#
# Checks, per DocumentsBackupSync* task:
#   - task exists, is Running, LastTaskResult is 0
#   - principal is the expected account, S4U, RunLevel Limited
#   - deployed watcher script, config dir and backup-config.json exist
#   - bucketAndPrefix is a valid bucket name (no '/')
#   - restic-password.txt exists and grants read to SYSTEM, Administrators
#     and the task account
#   - per-account config dir is writable by the task account (best effort)
#   - sync.log is recent, has no FATAL line, and points at the expected repo
#   - repository answers restic and holds at least one snapshot
#   - no duplicate agents (two tasks for the same repo, or legacy + per-account)
#
# Nothing is changed: no tasks are started/stopped, no files are written.
# Run elevated for complete ACL results.
#
# Exit code: 0 = all checks passed (warnings allowed), 1 = at least one FAIL.
#
#   .\verify-backup-agent.ps1                       # every backup task
#   .\verify-backup-agent.ps1 -TaskName DocumentsBackupSync-Acc2
#   .\verify-backup-agent.ps1 -SkipRepositoryCheck  # no network calls
# =====================================================================

param(
    [string]$TaskName = "",
    [switch]$SkipRepositoryCheck,
    [int]$LogMaxAgeHours = 24
)

$ErrorActionPreference = "Continue"
$PSNativeCommandUseErrorActionPreference = $false

$script:Pass = 0
$script:Warn = 0
$script:Fail = 0

function Add-Pass { param([string]$Message) $script:Pass++; Write-Host "[PASS] $Message" -ForegroundColor Green }
function Add-Warn { param([string]$Message) $script:Warn++; Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Add-Fail { param([string]$Message) $script:Fail++; Write-Host "[FAIL] $Message" -ForegroundColor Red }

# ---- Identity helpers -------------------------------------------------
function Get-AccountSid {
    param([string]$Identity)
    $t = "$Identity".Trim()
    if (-not $t) { return $null }
    if ($t -match '^S-1-5-') { return $t }
    try {
        return (New-Object System.Security.Principal.NTAccount($t)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Get-AccountName {
    param([string]$Identity)
    $t = "$Identity".Trim()
    if (-not $t) { return '' }
    if ($t -match '^S-1-5-') {
        try {
            return (New-Object System.Security.Principal.SecurityIdentifier($t)).Translate([System.Security.Principal.NTAccount]).Value
        } catch { return $t }
    }
    return $t
}

# Reads one "-Name value" or "-Name "value"" pair out of a task argument string.
function Get-ArgumentValue {
    param([string]$Arguments, [string]$Name)
    if (-not $Arguments) { return $null }
    $pattern = '(?:^|\s)-' + [regex]::Escape($Name) + '\s+(?:"([^"]*)"|(\S+))'
    $m = [regex]::Match($Arguments, $pattern)
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value }
    return $m.Groups[2].Value
}

function Test-AclHasRead {
    param($Acl, [string]$Sid)
    if (-not $Acl -or -not $Sid) { return $false }
    foreach ($ace in @($Acl.Access)) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        try { $aceSid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($aceSid -ne $Sid) { continue }
        if ("$($ace.FileSystemRights)" -match 'Read|Modify|FullControl') { return $true }
    }
    return $false
}

function Test-AclHasWrite {
    param($Acl, [string]$Sid)
    if (-not $Acl -or -not $Sid) { return $false }
    foreach ($ace in @($Acl.Access)) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        try { $aceSid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($aceSid -ne $Sid) { continue }
        if ("$($ace.FileSystemRights)" -match 'Modify|FullControl|Write') { return $true }
    }
    return $false
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "NOTE: not running elevated - some ACL/state results may be incomplete." -ForegroundColor Yellow
}

$BaseConfigDir = "$env:ProgramData\DocBackup"
$PasswordFile  = Join-Path $BaseConfigDir "restic-password.txt"
$resticExe     = $null
foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($pf) {
        $candidate = Join-Path $pf "restic\restic.exe"
        if (Test-Path -LiteralPath $candidate) { $resticExe = $candidate; break }
    }
}
if (-not $resticExe) {
    $cmd = Get-Command restic -ErrorAction SilentlyContinue
    if ($cmd) { $resticExe = $cmd.Source }
}

$allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -like 'DocumentsBackupSync*' } |
    Sort-Object TaskName)

if ($TaskName) {
    $allTasks = @($allTasks | Where-Object { $_.TaskName -eq $TaskName })
    if ($allTasks.Count -eq 0) {
        Write-Host "FAIL: task '$TaskName' not found." -ForegroundColor Red
        exit 1
    }
}
if ($allTasks.Count -eq 0) {
    Write-Host "FAIL: no DocumentsBackupSync* task found on this machine." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $PasswordFile)) {
    Add-Fail "Shared restic password file not found: $PasswordFile"
} else {
    Add-Pass "Shared restic password file exists: $PasswordFile"
}

# Duplicate / mixed-mode detection before the per-task loop.
$legacyTasks = @($allTasks | Where-Object { $_.TaskName -eq 'DocumentsBackupSync' })
$perAccountTasks = @($allTasks | Where-Object { $_.TaskName -like 'DocumentsBackupSync-*' })
if ($legacyTasks.Count -gt 0 -and $perAccountTasks.Count -gt 0) {
    Add-Warn "Mixed mode: legacy task 'DocumentsBackupSync' runs alongside per-account task(s) $($perAccountTasks.TaskName -join ', '). The console user's files may be backed up twice."
}
$repoSeen = @{}
foreach ($t in $allTasks) {
    $argsText = "$($t.Actions[0].Arguments)"
    $bid = Get-ArgumentValue -Arguments $argsText -Name 'BackupId'
    $cdir = Get-ArgumentValue -Arguments $argsText -Name 'ConfigDir'
    if (-not $bid) { $bid = $env:COMPUTERNAME }
    if (-not $cdir) { $cdir = $BaseConfigDir }
    $key = "$cdir|$bid".ToLowerInvariant()
    if ($repoSeen.ContainsKey($key)) {
        Add-Fail "Duplicate agents: '$($repoSeen[$key])' and '$($t.TaskName)' both target repo '$bid' in '$cdir'."
    } else {
        $repoSeen[$key] = $t.TaskName
    }
}

# Machine-level AWS keys are what the tasks actually see.
$awsAccess = [Environment]::GetEnvironmentVariable("AWS_ACCESS_KEY_ID", "Machine")
$awsSecret = [Environment]::GetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", "Machine")
if (-not $awsAccess -or -not $awsSecret) {
    Add-Warn "Machine-level AWS credentials are missing (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY). Agents cannot reach Wasabi."
}
if (-not $resticExe) {
    Add-Warn "restic.exe not found in Program Files or PATH."
}
if (-not $SkipRepositoryCheck -and (-not $resticExe -or -not $awsAccess -or -not $awsSecret)) {
    Write-Host "Repository checks will be skipped for these reasons." -ForegroundColor Yellow
}

foreach ($task in $allTasks) {
    Write-Host ""
    Write-Host "=== $($task.TaskName) ===" -ForegroundColor Cyan

    $argsText = "$($task.Actions[0].Arguments)"
    $principalRaw = "$($task.Principal.UserId)"
    $principalSid = Get-AccountSid -Identity $principalRaw
    $principalName = Get-AccountName -Identity $principalRaw

    $backupId = Get-ArgumentValue -Arguments $argsText -Name 'BackupId'
    $configDir = Get-ArgumentValue -Arguments $argsText -Name 'ConfigDir'
    $scriptPath = Get-ArgumentValue -Arguments $argsText -Name 'File'
    $isPerAccount = [bool]$backupId
    if (-not $backupId) { $backupId = $env:COMPUTERNAME }
    if (-not $configDir) { $configDir = $BaseConfigDir }
    if (-not $scriptPath) { $scriptPath = Join-Path $configDir 'sync-documents.ps1' }

    # --- Task state ---
    $state = "$($task.State)"
    $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -ErrorAction SilentlyContinue
    $lastResult = if ($info) { $info.LastTaskResult } else { $null }
    if ($state -eq 'Running') {
        Add-Pass "Task state: Running"
    } else {
        Add-Fail "Task state: '$state' - backups are not running. (A reboot with nobody logged on leaves the AtLogOn trigger unfired.)"
    }
    if ($null -ne $lastResult -and $lastResult -ne 0 -and $lastResult -ne 267009) {
        $hex = ''
        try { $hex = '0x{0:X8}' -f ([uint32]([int64]$lastResult -band 4294967295)) } catch { }
        Add-Fail ("LastTaskResult: {0} {1} - last run did not succeed." -f $lastResult, $hex)
    } elseif ($null -ne $lastResult -and $lastResult -eq 0) {
        Add-Pass "LastTaskResult: 0"
    }

    # --- Principal ---
    if (-not $principalSid) {
        Add-Fail "Task principal '$principalRaw' does not resolve to an account on this machine."
    } else {
        Add-Pass "Task runs as: $principalName ($principalSid)"
    }
    if ("$($task.Principal.LogonType)" -eq 'S4U') {
        Add-Pass "Logon type: S4U (survives logoff/lock)"
    } else {
        Add-Fail "Logon type is '$($task.Principal.LogonType)', expected S4U. The agent will die when the session ends."
    }
    if ("$($task.Principal.RunLevel)" -eq 'Highest') {
        Add-Warn "RunLevel is Highest; the expected least-privilege setting is Limited."
    }

    # --- Deployed files ---
    if (Test-Path -LiteralPath $scriptPath) {
        Add-Pass "Watcher script present: $scriptPath"
    } else {
        Add-Fail "Watcher script missing: $scriptPath"
    }
    if (Test-Path -LiteralPath $configDir) {
        Add-Pass "Config directory present: $configDir"
    } else {
        Add-Fail "Config directory missing: $configDir"
    }

    $expectedRepo = $null
    $cfgFile = Join-Path $configDir 'backup-config.json'
    if (-not (Test-Path -LiteralPath $cfgFile)) {
        if ($isPerAccount) {
            Add-Fail "backup-config.json missing from $configDir - the agent will refuse to start (per-account mode has no fallback)."
        } else {
            Add-Warn "backup-config.json missing from $configDir (legacy mode falls back to RESTIC_REPOSITORY)."
        }
    } else {
        try {
            $cfg = Get-Content -Path $cfgFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $ep = "$($cfg.wasabiEndpoint)".Trim().TrimEnd('/')
            $bkt = "$($cfg.bucketAndPrefix)".Trim().TrimEnd('/')
            if (-not $ep -or -not $bkt) {
                Add-Fail "backup-config.json is missing wasabiEndpoint or bucketAndPrefix."
            } elseif ($bkt.Contains('/')) {
                Add-Fail "bucketAndPrefix '$bkt' contains '/'. Fleet discovery and the agent's repo layout require a bucket name only."
            } else {
                $expectedRepo = "s3:$ep/$bkt/$backupId"
                Add-Pass "Config valid; expected repository: $expectedRepo"
            }
        } catch {
            Add-Fail "backup-config.json is not valid JSON: $($_.Exception.Message)"
        }
    }

    # --- Password file ACL ---
    if (Test-Path -LiteralPath $PasswordFile) {
        $acl = $null
        try { $acl = Get-Acl -LiteralPath $PasswordFile -ErrorAction Stop } catch { }
        if (-not $acl) {
            Add-Warn "Could not read the ACL of $PasswordFile."
        } else {
            foreach ($required in @(@{ Sid = 'S-1-5-18'; Label = 'SYSTEM' }, @{ Sid = 'S-1-5-32-544'; Label = 'Administrators' })) {
                if (Test-AclHasRead -Acl $acl -Sid $required.Sid) {
                    Add-Pass "Password file readable by $($required.Label)"
                } else {
                    Add-Fail "Password file is not explicitly readable by $($required.Label) ($($required.Sid))."
                }
            }
            if ($principalSid) {
                if (Test-AclHasRead -Acl $acl -Sid $principalSid) {
                    Add-Pass "Password file readable by the task account ($principalName)"
                } else {
                    Add-Fail "Password file is NOT explicitly readable by the task account ($principalName, $principalSid). The next backup will fail with 'Access is denied'. Run fix-password-file-access.ps1."
                }
            }
        }
    }

    # --- Config dir write access (per-account only; best effort) ---
    if ($isPerAccount -and $principalSid -and (Test-Path -LiteralPath $configDir)) {
        try {
            $dirAcl = Get-Acl -LiteralPath $configDir -ErrorAction Stop
            if (Test-AclHasWrite -Acl $dirAcl -Sid $principalSid) {
                Add-Pass "Task account can write its config directory"
            } else {
                Add-Warn "Task account has no explicit write ACE on $configDir. It may still work via inherited rights, but sync.log writes could fail - check sync.log after the first run."
            }
        } catch {
            Add-Warn "Could not read the ACL of $configDir."
        }
    }

    # --- Logs ---
    $logFile = Join-Path $configDir 'sync.log'
    if (-not (Test-Path -LiteralPath $logFile)) {
        Add-Warn "No sync.log yet at $logFile. The agent may not have completed its first run."
    } else {
        $logItem = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($logItem) {
            $logAge = (Get-Date) - $logItem.LastWriteTime
            if ($logAge.TotalHours -le $LogMaxAgeHours) {
                Add-Pass ("sync.log updated {0:N1} h ago" -f $logAge.TotalHours)
            } else {
                Add-Warn ("sync.log has not been updated for {0:N1} h (expected at least every {1} h)." -f $logAge.TotalHours, 15)
            }
        }
        $tail = @(Get-Content -Path $logFile -Tail 300 -ErrorAction SilentlyContinue)
        # Only the current process run matters: the agent logs "Watched paths"
        # once at startup and exits on a FATAL, so a FATAL from before the last
        # restart is history, not the state we are verifying now.
        $startIdx = -1
        for ($i = 0; $i -lt $tail.Count; $i++) {
            if ($tail[$i] -match 'Watched paths:') { $startIdx = $i }
        }
        $runLines = if ($startIdx -ge 0) { @($tail | Select-Object -Skip $startIdx) } else { $tail }
        $lastFailure = -1
        $lastSuccess = -1
        for ($i = 0; $i -lt $runLines.Count; $i++) {
            if ($runLines[$i] -match 'FATAL|Backup FAILED|Backup ERROR') { $lastFailure = $i }
            if ($runLines[$i] -match 'Backup completed successfully') { $lastSuccess = $i }
        }
        if ($lastFailure -ge 0 -and $lastFailure -gt $lastSuccess) {
            Add-Fail "Latest backup run reports a failure: $($runLines[$lastFailure])"
        } elseif ($lastFailure -ge 0) {
            Add-Pass "Latest backup succeeded (an earlier failure in this run was recovered)"
        } elseif ($lastSuccess -ge 0) {
            Add-Pass "sync.log shows a completed backup in the current run"
        } else {
            Add-Warn "No completed backup logged in the current run yet."
        }
        $repoLine = $runLines | Where-Object { $_ -match 'Repository:\s*(\S+)' } | Select-Object -Last 1
        if ($repoLine -and $repoLine -match 'Repository:\s*(\S+)') {
            $loggedRepo = $Matches[1]
            if ($expectedRepo) {
                if ($loggedRepo -eq $expectedRepo) {
                    Add-Pass "sync.log repository matches expected: $loggedRepo"
                } else {
                    Add-Fail "sync.log repository '$loggedRepo' does not match expected '$expectedRepo'."
                }
            }
        } elseif ($expectedRepo) {
            Add-Warn "sync.log does not contain a 'Repository:' line yet."
        }
        $watched = $runLines | Where-Object { $_ -match 'Watched paths:\s*(.+)$' } | Select-Object -Last 1
        if ($watched -and $watched -match 'Watched paths:\s*(.+)$') {
            $paths = $Matches[1].Trim()
            if ($isPerAccount -and $principalName) {
                $accountLeaf = ($principalName -split '\\')[-1]
                if ($paths -match [regex]::Escape($accountLeaf)) {
                    Add-Pass "Watched paths look account-scoped: $paths"
                } else {
                    Add-Warn "Watched paths do not mention '$accountLeaf': $paths. This is expected if folders are redirected (OneDrive/UNC); otherwise the task may be watching the wrong profile."
                }
            }
        }
    }

    # --- Repository (read-only restic call) ---
    if ($SkipRepositoryCheck) {
        Write-Host "Repository check skipped (-SkipRepositoryCheck)." -ForegroundColor Yellow
    } elseif (-not $expectedRepo) {
        Add-Warn "Repository check skipped: expected repository could not be derived."
    } elseif (-not $resticExe) {
        Add-Warn "Repository check skipped: restic.exe not found."
    } elseif (-not $awsAccess -or -not $awsSecret) {
        Add-Warn "Repository check skipped: machine AWS credentials are missing."
    } elseif (-not (Test-Path -LiteralPath $PasswordFile)) {
        Add-Warn "Repository check skipped: password file missing."
    } else {
        $savedEnv = @{
            AWS_ACCESS_KEY_ID     = $env:AWS_ACCESS_KEY_ID
            AWS_SECRET_ACCESS_KEY = $env:AWS_SECRET_ACCESS_KEY
            RESTIC_REPOSITORY     = $env:RESTIC_REPOSITORY
            RESTIC_PASSWORD_FILE  = $env:RESTIC_PASSWORD_FILE
        }
        try {
            $env:AWS_ACCESS_KEY_ID = $awsAccess
            $env:AWS_SECRET_ACCESS_KEY = $awsSecret
            $env:RESTIC_REPOSITORY = $expectedRepo
            $env:RESTIC_PASSWORD_FILE = $PasswordFile
            $snapRaw = (& $resticExe --no-cache snapshots --json 2>&1 | Out-String)
            $snapCode = $LASTEXITCODE
            if ($snapCode -ne 0) {
                Add-Fail "restic could not read $expectedRepo (exit $snapCode): $($snapRaw.Trim())"
            } else {
                try {
                    $snaps = @(($snapRaw | ConvertFrom-Json))
                    if ($snaps.Count -eq 0) {
                        Add-Fail "Repository $expectedRepo exists but has no snapshots."
                    } else {
                        Add-Pass "Repository reachable with $($snaps.Count) snapshot(s)"
                        $badTags = @($snaps | Where-Object { -not $_.tags -or $_.tags -notcontains $backupId })
                        if ($badTags.Count -gt 0) {
                            Add-Warn "$($badTags.Count) snapshot(s) do not carry tag '$backupId' (mixed/legacy data in this repo?)."
                        }
                    }
                } catch {
                    Add-Warn "Could not parse restic snapshot output: $($_.Exception.Message)"
                }
            }
        } finally {
            foreach ($k in $savedEnv.Keys) {
                if ($null -eq $savedEnv[$k]) {
                    Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue
                } else {
                    Set-Item -Path "env:$k" -Value $savedEnv[$k] -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

Write-Host ""
Write-Host "=== Summary: $script:Pass passed, $script:Warn warning(s), $script:Fail failed ===" -ForegroundColor Cyan
if ($script:Fail -gt 0) {
    Write-Host "RESULT: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: PASS" -ForegroundColor Green
exit 0
