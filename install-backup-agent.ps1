# =====================================================================
# install-backup-agent.ps1  (restic edition)
# One-time setup, run ONCE per laptop as Administrator:
#   powershell -ExecutionPolicy Bypass -File install-backup-agent.ps1
#
# Installs restic, provisions a per-laptop encrypted repository on
# Wasabi S3, deploys the continuous backup watcher, and registers it
# as a Scheduled Task that starts at logon and restarts automatically.
# =====================================================================

$ErrorActionPreference = "Stop"

# ---- Re-launch elevated if not already admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ---- Config: Wasabi connection details ----
$WasabiEndpoint = "https://s3.eu-south-1.wasabisys.com"
$BucketAndPrefix = "ssrms-bucket"   # <-- the bucket name of wasabi, plus optional prefix for restic repos (e.g. "ssrms-bucket")
$HostName   = $env:COMPUTERNAME

Write-Host ""
Write-Host "================== Starting Documents Backup Agent Installer on $HostName ============================="
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
$ConfigDir  = "$env:ProgramData\DocBackup\"
$ScriptDest = Join-Path $ConfigDir "sync-documents.ps1"
$PasswordFile = Join-Path $ConfigDir "restic-password.txt"

$Repository = "s3:$WasabiEndpoint/$BucketAndPrefix/$HostName"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null

# ---- 1. Install restic if not already present ----
$resticExe = Join-Path $InstallDir "restic.exe"
if (-not (Test-Path $resticExe)) {

    Write-Host "Looking up latest restic release in $InstallDir"

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/restic/restic/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like "*windows_amd64.zip" } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a Windows restic release asset." }

    Write-Host "Downloading restic $($release.tag_name)..."
    
    $zipPath = "$env:TEMP\restic.zip"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    $extractDir = "$env:TEMP\restic-extract"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $exeFound = Get-ChildItem -Path $extractDir -Filter "restic*.exe" -Recurse | Select-Object -First 1
    Copy-Item -Path $exeFound.FullName -Destination $resticExe -Force
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

# ---- 2. Store the restic password in a restricted, IT-only-readable file ----
# (Not a plain machine env var — this is the key that decrypts everything,
#  so it gets filesystem ACLs restricting it to SYSTEM and Administrators.)
Set-Content -Path $PasswordFile -Value $ResticPassword -NoNewline
icacls $PasswordFile /inheritance:r | Out-Null
icacls $PasswordFile /grant:r "SYSTEM:(R)" "BUILTIN\Administrators:(R)" | Out-Null

# ---- 3. Set machine-wide environment variables restic needs ----
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

# ---- 4. Initialize the repository if it doesn't already exist ----
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & $resticExe snapshots > $null 2>&1
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "Initializing new restic repository..."
    & $resticExe init
    if ($LASTEXITCODE -ne 0) {
        throw "restic init failed check Wasabi credentials/bucket name and try again."
    }
    Write-Host "Repository initialized and encrypted."
} else {
    Write-Host "Repository already exists, skipping init."
}

# ---- 5. Deploy the watcher script ----
# (Assumes sync-documents.ps1 sits next to this installer)
$sourceScript = Join-Path $PSScriptRoot "sync-documents.ps1"
Copy-Item -Path $sourceScript -Destination $ScriptDest -Force
Write-Host "Watcher script deployed to $ScriptDest"

# ---- 6. Register Scheduled Task: run at logon, restart on failure ----
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

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Scheduled task '$TaskName' registered (starts at logon, auto-restarts)."

# ---- 7. Start it now for this session too ----
Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "=== Install complete =============================================================="
Write-Host "Backing up: $([Environment]::GetFolderPath('MyDocuments'))"
Write-Host "Repository: $Repository"
Write-Host "Encryption: restic (AES-256-CTR + Poly1305), password stored in $PasswordFile (restricted to SYSTEM/Administrators)"
Write-Host "Logs: $ConfigDir\sync.log"
Write-Host "Scheduled Task: $TaskName (starts at logon, auto-restarts on failure)"
Write-Host "========================= End of install-backup-agent ============================="
