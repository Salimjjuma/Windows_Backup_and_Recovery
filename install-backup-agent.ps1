# =====================================================================
# install-backup-agent.ps1  (restic edition)
# One-time setup, run as Administrator:
#   powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1
#
# Two naming modes:
#   default     - one repository + task per laptop, named after
#                 COMPUTERNAME. This is the original behaviour and is
#                 unchanged for existing single-account laptops.
#   -PerAccount - one repository + task per Windows account, named
#                 COMPUTERNAME-<account> (e.g. LAPTOP-1-Acc2), each
#                 running as that account. Use this to back up two or
#                 more local accounts on the same laptop.
#
# Shared endpoint/bucket/excludes come from backup-config.json when it
# sits next to this script (see README); otherwise built-in defaults are
# used, which match the old hard-coded values.
# =====================================================================

param(
    # Staff owner's logon (DOMAIN\user or COMPUTER\user). If omitted, auto-
    # detected from the current console session (Win32_ComputerSystem.UserName).
    # Do NOT default to $env:USERNAME here: under elevation that is the IT
    # admin account, not the staff owner, and the task would watch the wrong
    # profile.
    [string]$TaskUser = "",

    # Extra folders to back up for THIS account/laptop only (e.g.
    # "C:\Users\Public"). Appended (deduped) to extra-paths.txt on every
    # run, including re-runs.
    [string[]]$ExtraPaths = @(),

    # Enable per-account mode: repo/tag/task/config-dir keyed by the
    # account instead of the machine name.
    [switch]$PerAccount,

    # Override the derived backup ID (repo suffix + snapshot tag). Usually
    # unnecessary; useful if an account name sanitises oddly or a repo was
    # created under a different name.
    [string]$BackupId = "",

    # Optional overrides for the shared backup-config.json values.
    [string]$WasabiEndpoint = "",
    [string]$BucketAndPrefix = ""
)

$ErrorActionPreference = "Continue"
# NOT "Stop": this script repeatedly runs restic.exe and checks
# $LASTEXITCODE, including cases where a non-zero exit / stderr output is
# expected and normal (e.g. checking whether a repository already
# exists). With ErrorActionPreference = "Stop", PowerShell converts any
# text a native command writes to stderr into a terminating exception
# BEFORE stream redirection (> $null 2>&1) gets a chance to suppress it -
# so those checks would throw instead of just setting $LASTEXITCODE.
# Cmdlet calls below that should hard-fail the script use explicit
# -ErrorAction Stop instead of relying on this global setting.
$PSNativeCommandUseErrorActionPreference = $false

# ---- Shared configuration (optional file next to this script) ----
function Read-BackupConfig {
    $candidates = @()
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot "backup-config.json") }
    $candidates += (Join-Path (Get-Location).Path "backup-config.json")
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) {
            try {
                return Get-Content -Path $p -Raw -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-Warning "Could not read ${p}: $($_.Exception.Message)"
            }
        }
    }
    return $null
}

$BackupConfig = Read-BackupConfig

# Built-in fallback excludes. Kept identical to the old hard-coded list so a
# laptop without backup-config.json behaves exactly as before.
$DefaultExcludes = @(
    "# restic exclude patterns - one glob pattern per line, # for comments",
    "# Temp / lock files",
    "*.tmp",
    "~`$*",
    "desktop.ini",
    "# Media files excluded from backup per IT policy",
    "*.mp4",
    "*.mp3",
    "*.jpeg",
    "*.jpg",
    "*.png"
)
$ConfiguredExcludes = $DefaultExcludes
if ($BackupConfig -and $BackupConfig.excludes) {
    $ConfiguredExcludes = @($BackupConfig.excludes | ForEach-Object { "$_" })
}
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

# ---- Re-launch elevated if not already admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    $fwdArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($TaskUser) { $fwdArgs += " -TaskUser `"$TaskUser`"" }
    if ($ExtraPaths -and $ExtraPaths.Count -gt 0) {
        $fwdArgs += " -ExtraPaths " + (($ExtraPaths | ForEach-Object { "'$_'" }) -join ",")
    }
    if ($PerAccount) { $fwdArgs += " -PerAccount" }
    if ($BackupId) { $fwdArgs += " -BackupId `"$BackupId`"" }
    if ($WasabiEndpoint) { $fwdArgs += " -WasabiEndpoint `"$WasabiEndpoint`"" }
    if ($BucketAndPrefix) { $fwdArgs += " -BucketAndPrefix `"$BucketAndPrefix`"" }
    Start-Process powershell -Verb RunAs -ArgumentList $fwdArgs
    exit
}

# ---- Resolve the account, backup ID, directories and task name ----
# Prefer the logged-on console user, NOT $env:USERNAME (under elevation that
# is the IT admin, whose Documents/Desktop are not what we want to back up).
# -TaskUser overrides.
if (-not $TaskUser) {
    $loggedOn = $null
    try { $loggedOn = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
    if ($loggedOn) { $TaskUser = $loggedOn }
    else { $TaskUser = "$env:USERDOMAIN\$env:USERNAME" }
}

$HostName    = $env:COMPUTERNAME
$AccountName = ($TaskUser -split '\\')[-1]
# Account names can contain spaces/dots/accented characters. Keep the repo,
# task and folder names conservative so S3 prefixes and icacls stay simple.
$SafeAccount = ($AccountName -replace '[^A-Za-z0-9._-]', '-').Trim('-')

if ($PerAccount -and -not $SafeAccount) {
    throw "Could not derive an account name from '$TaskUser'. Pass -TaskUser COMPUTER\account."
}
if ($PerAccount -and -not $BackupId) { $BackupId = "$HostName-$SafeAccount" }
if (-not $BackupId) { $BackupId = $HostName }
$Tag = $BackupId

$BaseConfigDir = "$env:ProgramData\DocBackup"
if ($PerAccount) {
    $ConfigDir = Join-Path (Join-Path $BaseConfigDir "Accounts") $SafeAccount
} else {
    $ConfigDir = $BaseConfigDir
}
# The restic password is shared by every account/laptop, so it stays in the
# base directory even when per-account logs/state live in a subfolder.
$PasswordFile   = Join-Path $BaseConfigDir "restic-password.txt"
$ScriptDest     = Join-Path $ConfigDir "sync-documents.ps1"
$ExcludeFile    = Join-Path $ConfigDir "excludes.txt"
$ExtraPathsFile = Join-Path $ConfigDir "extra-paths.txt"
$TaskName       = if ($PerAccount) { "DocumentsBackupSync-$SafeAccount" } else { "DocumentsBackupSync" }
$Repository     = "s3:$WasabiEndpoint/$BucketAndPrefix/$BackupId"

# restic location: prefer an existing install in either Program Files root
# (a 32-bit PowerShell session reports Program Files (x86)).
$ProgramFilesDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { $_ } | Select-Object -Unique
if (-not $ProgramFilesDirs -or $ProgramFilesDirs.Count -eq 0) {
    $ProgramFilesDirs = @("C:\Program Files")
}
$InstallDir = Join-Path ($ProgramFilesDirs[0]) "restic"
foreach ($pf in $ProgramFilesDirs) {
    if (Test-Path (Join-Path $pf "restic\restic.exe")) {
        $InstallDir = Join-Path $pf "restic"
        break
    }
}
$resticExe = Join-Path $InstallDir "restic.exe"

Write-Host ""
Write-Host "=== Starting Documents Backup Agent Installer for $HostName ==="
Write-Host "Mode:        $(if ($PerAccount) { 'per-account' } else { 'per-laptop (legacy)' })"
Write-Host "Backup ID:   $BackupId"
Write-Host "Task:        $TaskName"
Write-Host "Config dir:  $ConfigDir"
Write-Host ""

# ---- Install progress (0-100% across the 8 steps below) ----
$TotalSteps = 8
function Show-InstallProgress {
    param([int]$Step, [string]$Status)
    $pct = [math]::Round($Step / $TotalSteps * 100)
    Write-Progress -Activity "Installing Documents Backup Agent ($HostName)" `
        -Status "Step $Step of $TotalSteps - $Status" -PercentComplete $pct
}
Show-InstallProgress -Step 0 -Status "Collecting credentials"

# Re-run friendly: default to already-saved machine values so Enter keeps
# them (e.g. when re-running just to add -ExtraPaths or update the
# watcher). Typing a value rotates it.
$savedAccess = [Environment]::GetEnvironmentVariable("AWS_ACCESS_KEY_ID", "Machine")
$savedSecret = [Environment]::GetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", "Machine")
$savedPwFile = [Environment]::GetEnvironmentVariable("RESTIC_PASSWORD_FILE", "Machine")
$effectivePwFile = if ($savedPwFile) { $savedPwFile } else { $PasswordFile }
$savedPwExists = $false
try { $savedPwExists = Test-Path $effectivePwFile } catch { }

if ($savedAccess) {
    $masked = $savedAccess.Substring(0, [Math]::Min(4, $savedAccess.Length)) + "..."
    $inKey = Read-Host "Enter Wasabi Access Key ID [Enter to keep existing '$masked']"
    $AccessKey = if ($inKey -and $inKey.Trim()) { $inKey.Trim() } else { $savedAccess }
} else {
    $AccessKey = Read-Host "Enter Wasabi Access Key ID"
}
if ($savedSecret) {
    $inSecretSecure = Read-Host "Enter Wasabi Secret Access Key [Enter to keep saved]" -AsSecureString
    $inSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($inSecretSecure)
    )
    $SecretKey = if ($inSecret) { $inSecret } else { $savedSecret }
} else {
    $SecretKeySecure = Read-Host "Enter Wasabi Secret Access Key" -AsSecureString
    $SecretKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecretKeySecure)
    )
}
if ($savedPwExists) {
    $inPwSecure = Read-Host "Enter the restic repository encryption password [Enter to keep existing file]" -AsSecureString
    $inPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($inPwSecure)
    )
    if ($inPw) {
        $ResticPassword = $inPw
    } else {
        try { $ResticPassword = Get-Content -Path $effectivePwFile -Raw -ErrorAction Stop }
        catch {
            Write-Host "Could not read existing password file, please enter the password."
            $retrySecure = Read-Host "Enter the restic repository encryption password (same for all laptops, kept by IT only)" -AsSecureString
            $ResticPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($retrySecure)
            )
        }
    }
} else {
    $ResticPasswordSecure = Read-Host "Enter the restic repository encryption password (same for all laptops, kept by IT only)" -AsSecureString
    $ResticPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ResticPasswordSecure)
    )
}
if (-not $ExtraPaths -or $ExtraPaths.Count -eq 0) {
    $extraAnswer = Read-Host "Extra folders to back up on THIS laptop, comma-separated (e.g. C:\Users\Public) [Enter to skip]"
    if ($extraAnswer -and $extraAnswer.Trim()) {
        $ExtraPaths = @($extraAnswer -split "[,;]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null

# ---- 1. Install restic if not already present ----
Show-InstallProgress -Step 1 -Status "Installing restic"
if (-not (Test-Path $resticExe)) {
    # Detect OS architecture - 32-bit laptops need the windows_386 build, not windows_amd64
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    Write-Host "Detected architecture: $arch"

    Write-Host "Looking up latest restic release..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/restic/restic/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like "*windows_$arch.zip" } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a Windows ($arch) restic release asset." }

    Write-Host "Downloading restic $($release.tag_name) ($arch)..."
    $zipPath = "$env:TEMP\restic.zip"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -ErrorAction Stop
    $extractDir = "$env:TEMP\restic-extract"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop
    $exeFound = Get-ChildItem -Path $extractDir -Filter "restic*.exe" -Recurse | Select-Object -First 1
    Copy-Item -Path $exeFound.FullName -Destination $resticExe -Force -ErrorAction Stop
    Remove-Item $zipPath, $extractDir -Recurse -Force
    Write-Host "restic installed to $InstallDir"
} else {
    Write-Host "restic already installed, skipping download."
}

# Add to machine PATH if not already present
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$InstallDir", "Machine")
    $env:Path += ";$InstallDir"
}

# ---- 2. Create the default excludes file (if not already present) ----
Show-InstallProgress -Step 2 -Status "Creating excludes file"
# Patterns come from backup-config.json when present. IT staff can still edit
# the deployed file directly to adjust patterns without touching any script.
if (-not (Test-Path $ExcludeFile)) {
    $ConfiguredExcludes | Set-Content -Path $ExcludeFile
    Write-Host "Default excludes file created at $ExcludeFile"
} else {
    Write-Host "Excludes file already exists at $ExcludeFile, leaving as-is."
}

# ---- 2b. Extra backup folders (this account/laptop only) ----
# Appended (deduped), never overwritten, so re-runs are safe. The watcher
# unions these with Documents + Desktop at runtime.
$cleanExtra = @($ExtraPaths | ForEach-Object { "$_".Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") } |
    Select-Object -Unique)
if ($cleanExtra.Count -gt 0) {
    $existing = @()
    if (Test-Path $ExtraPathsFile) {
        $existing = @(Get-Content -Path $ExtraPathsFile |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    @($existing + $cleanExtra | Select-Object -Unique) |
        Set-Content -Path $ExtraPathsFile
    Write-Host "Extra backup folders recorded in $ExtraPathsFile"
}

# ---- 3. Store the restic password in a restricted, IT-only-readable file ----
Show-InstallProgress -Step 3 -Status "Securing repository password"
# Not a plain machine env var - this is the key that decrypts everything, so
# it gets filesystem ACLs restricting it to SYSTEM, Administrators, and every
# account whose scheduled task needs it. In per-account mode that means *all*
# provisioned task users, not just the one being installed now; otherwise
# re-running the installer for Acc2 would lock Acc1 out (and vice versa).
# Reset any ACL left over from a previous install run before writing, so this
# script is safe to re-run.
Write-Host "Scheduled task will run as: $TaskUser"
if (Test-Path $PasswordFile) {
    icacls $PasswordFile /reset | Out-Null
}
Set-Content -Path $PasswordFile -Value $ResticPassword -NoNewline
icacls $PasswordFile /inheritance:r | Out-Null

$grantIdentities = @("SYSTEM", "BUILTIN\Administrators", $TaskUser)
try {
    $existingTaskUsers = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -like 'DocumentsBackupSync*' } |
        ForEach-Object { $_.Principal.UserId })
    $grantIdentities += $existingTaskUsers
} catch { }

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
$aclArgs = @($PasswordFile, "/grant:r") + @($uniqueIds | ForEach-Object { "${_}:(R)" })
& icacls @aclArgs | Out-Null

# ---- 4. Set machine-wide environment variables restic needs ----
Show-InstallProgress -Step 4 -Status "Setting environment variables"
[Environment]::SetEnvironmentVariable("AWS_ACCESS_KEY_ID", $AccessKey, "Machine")
[Environment]::SetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", $SecretKey, "Machine")
[Environment]::SetEnvironmentVariable("RESTIC_PASSWORD_FILE", $PasswordFile, "Machine")

if ($PerAccount) {
    # Do not clobber a legacy machine-wide repo: the original single-account
    # task may still be running and relies on it. Per-account tasks resolve
    # their own repo from backup-config.json + -BackupId. Only seed the value
    # for manual `restic` use when nothing is set yet.
    $existingRepo = [Environment]::GetEnvironmentVariable("RESTIC_REPOSITORY", "Machine")
    if (-not $existingRepo) {
        [Environment]::SetEnvironmentVariable("RESTIC_REPOSITORY", $Repository, "Machine")
    }
} else {
    [Environment]::SetEnvironmentVariable("RESTIC_REPOSITORY", $Repository, "Machine")
}

# Also set for this session so init/checks below work immediately
$env:AWS_ACCESS_KEY_ID = $AccessKey
$env:AWS_SECRET_ACCESS_KEY = $SecretKey
$env:RESTIC_REPOSITORY = $Repository
$env:RESTIC_PASSWORD_FILE = $PasswordFile

Write-Host "Repository target: $Repository"

# ---- 5. Initialize the repository if it doesn't already exist ----
Show-InstallProgress -Step 5 -Status "Initializing repository"
& $resticExe snapshots > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Initializing new restic repository..."
    & $resticExe init
    if ($LASTEXITCODE -ne 0) {
        Write-Progress -Activity "Installing Documents Backup Agent ($HostName)" -Completed
        throw "restic init failed - check Wasabi credentials/bucket name and try again."
    }
    Write-Host "Repository initialized and encrypted."
} else {
    Write-Host "Repository already exists, skipping init."
}

# ---- 6. Deploy the watcher script and shared config ----
Show-InstallProgress -Step 6 -Status "Deploying watcher script"
# (Assumes sync-documents.ps1 sits next to this installer)
$sourceScript = Join-Path $PSScriptRoot "sync-documents.ps1"
Copy-Item -Path $sourceScript -Destination $ScriptDest -Force -ErrorAction Stop
Write-Host "Watcher script deployed to $ScriptDest"

# Shared endpoint/bucket/excludes. Always (re)written from the resolved
# values so the deployed agent cannot disagree with what the installer just
# used - including when no backup-config.json ships next to the installer.
# excludes.txt itself is left alone, so local pattern edits survive.
$destBackupConfig = Join-Path $ConfigDir "backup-config.json"
$configObject = [PSCustomObject]@{
    wasabiEndpoint  = $WasabiEndpoint
    bucketAndPrefix = $BucketAndPrefix
    excludes        = @($ConfiguredExcludes)
}
# Write UTF-8 without a BOM: Get-Content handles either, but the Linux fleet
# tools parse this file with Python's json module, which rejects a BOM.
$configJson = $configObject | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText(
    $destBackupConfig,
    $configJson,
    (New-Object System.Text.UTF8Encoding($false))
)
Write-Host "Shared backup config deployed to $destBackupConfig"

# Retention policy file: the single source of truth the agent prunes with and
# the IT fleet tools (check-fleet.ps1/.sh, fleet-dashboard.py) read, so the
# prune backlog column matches what this laptop actually does. Copied only if
# absent, so a per-laptop override survives a re-run. If this installer has no
# retention.json beside it, the agent falls back to the built-in defaults.
$sourceRetention = Join-Path $PSScriptRoot "retention.json"
$destRetention   = Join-Path $ConfigDir "retention.json"
if (Test-Path $sourceRetention) {
    if (Test-Path $destRetention) {
        Write-Host "Retention policy already present at $destRetention, leaving as-is."
    } else {
        Copy-Item -Path $sourceRetention -Destination $destRetention -Force -ErrorAction Stop
        Write-Host "Retention policy deployed to $destRetention"
    }
} else {
    Write-Host "No retention.json next to the installer - agent will use built-in defaults (14/8/12)."
}

# ---- 7. Register Scheduled Task: run at logon, restart on failure ----
Show-InstallProgress -Step 7 -Status "Registering scheduled task"

# In per-account mode this only touches THIS account's task, so installing
# Acc2 never unregisters Acc1. In legacy mode the name is unchanged.
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$actionArgument = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptDest`""
if ($PerAccount) {
    $actionArgument += " -BackupId `"$BackupId`" -ConfigDir `"$ConfigDir`""
}
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgument

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

# S4U ("run whether user is logged on or not", no stored password) instead
# of Interactive: an Interactive-logon task is tied to that console
# session, so Windows kills it with STATUS_CONTROL_C_EXIT the moment the
# session ends (lock, logoff, disconnect) - fatal for a background agent
# that's supposed to run continuously. S4U detaches the process from the
# interactive session while still running as this user (so it can access
# their Documents/Desktop/Downloads), and survives logoff/lock.
$principal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType S4U -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null

Write-Host "Scheduled task '$TaskName' registered (starts at logon, auto-restarts)."

# ---- 8. Start it now for this session too ----
Show-InstallProgress -Step 8 -Status "Starting backup task"
Start-ScheduledTask -TaskName $TaskName
Write-Progress -Activity "Installing Documents Backup Agent ($HostName)" -Completed

Write-Host ""
Write-Host "=== Install complete ==="
Write-Host "Mode: $(
    if ($PerAccount) { "per-account ($BackupId)" } else { "per-laptop (legacy)" }
)"
Write-Host "Backing up: Documents and Desktop folders"
Write-Host "Repository: $Repository"
Write-Host "Encryption: restic (AES-256-CTR + Poly1305), password stored in $PasswordFile (restricted to SYSTEM/Administrators/task users)"
Write-Host "Logs: $ConfigDir\sync.log"
Write-Host "Scheduled Task: $TaskName (starts at logon, auto-restarts on failure)"
Write-Host "========================= End of install-backup-agent ============================="
