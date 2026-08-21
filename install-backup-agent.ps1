# =====================================================================
# install-backup-agent.ps1  (restic edition)
# One-time setup, run ONCE per laptop as Administrator:
#   powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1
#
# Installs restic, provisions a per-laptop encrypted repository on
# Wasabi S3, deploys the continuous backup watcher, and registers it
# as a Scheduled Task that starts at logon and restarts automatically.
# =====================================================================

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

# ---- Re-launch elevated if not already admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ---- Config: Wasabi connection details ----
$WasabiEndpoint = "https://s3.eu-south-1.wasabisys.com"
$BucketAndPrefix = "ssrms-bucket"   # <-- set your actual bucket name here
$HostName   = $env:COMPUTERNAME

Write-Host ""
Write-Host "=== Starting Documents Backup Agent Installer for $HostName ==="
Write-Host ""
$AccessKey = Read-Host "Enter Wasabi Access Key ID"
$SecretKeySecure = Read-Host "Enter Wasabi Secret Access Key" -AsSecureString
$SecretKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecretKeySecure)
)
$ResticPasswordSecure = Read-Host "Enter the restic repository encryption password (same for all laptops, kept by IT only)" -AsSecureString
$ResticPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ResticPasswordSecure)
)

$InstallDir = "C:\Program Files\restic"
$ConfigDir  = "$env:ProgramData\DocBackup"
$ScriptDest = Join-Path $ConfigDir "sync-documents.ps1"
$PasswordFile = Join-Path $ConfigDir "restic-password.txt"

$Repository = "s3:$WasabiEndpoint/$BucketAndPrefix/$HostName"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null

# ---- 1. Install restic if not already present ----
$resticExe = Join-Path $InstallDir "restic.exe"
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
# Media files are excluded by default per IT policy. IT staff can edit
# this file directly on any laptop to adjust patterns without touching
# any script.
$ExcludeFile = Join-Path $ConfigDir "excludes.txt"
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
    Write-Host "Default excludes file created at $ExcludeFile"
} else {
    Write-Host "Excludes file already exists at $ExcludeFile, leaving as-is."
}

# ---- 3. Store the restic password in a restricted, IT-only-readable file ----
# (Not a plain machine env var - this is the key that decrypts everything,
#  so it gets filesystem ACLs restricting it to SYSTEM, Administrators, and
#  the specific user account the Scheduled Task runs as. The task runs as
#  the interactive user (see section 7 below), NOT as SYSTEM or an admin, so that
#  account must be explicitly granted - otherwise the backup fails with
#  "Access is denied" trying to read this file.)
# Reset any ACL left over from a previous install run before writing, so
# this script is safe to re-run (e.g. to rotate the password or update
# other components) without locking itself out.
$TaskUser = "$env:USERDOMAIN\$env:USERNAME"
if (Test-Path $PasswordFile) {
    icacls $PasswordFile /reset | Out-Null
}
Set-Content -Path $PasswordFile -Value $ResticPassword -NoNewline
icacls $PasswordFile /inheritance:r | Out-Null
icacls $PasswordFile /grant:r "SYSTEM:(R)" "BUILTIN\Administrators:(R)" "${TaskUser}:(R)" | Out-Null

# ---- 4. Set machine-wide environment variables restic needs ----
[Environment]::SetEnvironmentVariable("AWS_ACCESS_KEY_ID", $AccessKey, "Machine")
[Environment]::SetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", $SecretKey, "Machine")
[Environment]::SetEnvironmentVariable("RESTIC_REPOSITORY", $Repository, "Machine")
[Environment]::SetEnvironmentVariable("RESTIC_PASSWORD_FILE", $PasswordFile, "Machine")

# Also set for this session so init/checks below work immediately
$env:AWS_ACCESS_KEY_ID = $AccessKey
$env:AWS_SECRET_ACCESS_KEY = $SecretKey
$env:RESTIC_REPOSITORY = $Repository
$env:RESTIC_PASSWORD_FILE = $PasswordFile

Write-Host "Repository target: $Repository"

# ---- 5. Initialize the repository if it doesn't already exist ----
& $resticExe snapshots > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Initializing new restic repository..."
    & $resticExe init
    if ($LASTEXITCODE -ne 0) {
        throw "restic init failed - check Wasabi credentials/bucket name and try again."
    }
    Write-Host "Repository initialized and encrypted."
} else {
    Write-Host "Repository already exists, skipping init."
}

# ---- 6. Deploy the watcher script ----
# (Assumes sync-documents.ps1 sits next to this installer)
$sourceScript = Join-Path $PSScriptRoot "sync-documents.ps1"
Copy-Item -Path $sourceScript -Destination $ScriptDest -Force -ErrorAction Stop
Write-Host "Watcher script deployed to $ScriptDest"

# ---- 7. Register Scheduled Task: run at logon, restart on failure ----
$TaskName = "DocumentsBackupSync"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptDest`""

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
Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "=== Install complete ==="
Write-Host "Backing up: Documents, Desktop, and Downloads folders"
Write-Host "Repository: $Repository"
Write-Host "Encryption: restic (AES-256-CTR + Poly1305), password stored in $PasswordFile (restricted to SYSTEM/Administrators)"
Write-Host "Logs: $ConfigDir\sync.log"
Write-Host "Scheduled Task: $TaskName (starts at logon, auto-restarts on failure)"
Write-Host "========================= End of install-backup-agent ============================="
