# =====================================================================
# uninstall-backup-agent.ps1
# Removes the Documents backup agent provisioned by
# install-backup-agent.ps1. Run ONCE per laptop as Administrator:
#   powershell -ExecutionPolicy Bypass -File uninstall-backup-agent.ps1
#
# Does, in order:
#   1. Stops + unregisters the Scheduled Task (DocumentsBackupSync)
#   2. Stops any running watcher (sync-documents.ps1) processes
#   3. Deletes the machine-level env keys restic needs
#   4. Deletes the restic password file
#
# Optional: -Full also removes restic.exe, the deployed watcher copy,
#   excludes/extra-paths files, and logs under C:\ProgramData\DocBackup.
# =====================================================================

param(
    [string]$TaskName = "DocumentsBackupSync",
    [string]$ConfigDir = "$env:ProgramData\DocBackup",
    [switch]$Full
)

$ErrorActionPreference = "Continue"
$PSNativeCommandUseErrorActionPreference = $false

# ---- Re-launch elevated if not already admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Relaunching as Administrator..."
    $fwdArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($TaskName -ne "DocumentsBackupSync") { $fwdArgs += " -TaskName `"$TaskName`"" }
    if ($ConfigDir -ne "$env:ProgramData\DocBackup") { $fwdArgs += " -ConfigDir `"$ConfigDir`"" }
    if ($Full) { $fwdArgs += " -Full" }
    Start-Process powershell -Verb RunAs -ArgumentList $fwdArgs
    exit
}

$PasswordFile = Join-Path $ConfigDir "restic-password.txt"
$EnvVars = @("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "RESTIC_REPOSITORY", "RESTIC_PASSWORD_FILE")

Write-Host ""
Write-Host "=== Uninstalling Documents Backup Agent ==="
Write-Host ""

# ---- 1. Stop + unregister the Scheduled Task ----
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Scheduled task '$TaskName' stopped."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop | Out-Null
    Write-Host "Scheduled task '$TaskName' removed."
} else {
    Write-Host "Scheduled task '$TaskName' not found, skipping."
}

# ---- 2. Stop any running watcher processes (sync-documents.ps1) ----
# The FileSystemWatchers live inside these powershell.exe processes, so
# killing them is what actually stops the watchers. Exclude this uninstall
# script's own process.
$myPid = $PID
$stopped = 0
try {
    $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*sync-documents.ps1*" -and $_.ProcessId -ne $myPid }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped watcher process (PID $($p.ProcessId))."
            $stopped++
        } catch {
            Write-Host "Could not stop PID $($p.ProcessId): $_"
        }
    }
} catch {
    Write-Host "Watcher process lookup skipped: $_"
}
if ($stopped -eq 0) { Write-Host "No running watcher processes found." }

# ---- 3. Delete the machine-level env keys ----
foreach ($v in $EnvVars) {
    try {
        [Environment]::SetEnvironmentVariable($v, $null, "Machine")
        # Also clear from this session so a stale value can't leak into later commands
        [Environment]::SetEnvironmentVariable($v, $null, "Process")
        Write-Host "Env var removed (Machine + Process): $v"
    } catch {
        Write-Host "Could not remove env var ${v}: $_"
    }
}

# ---- 4. Delete the password file ----
if (Test-Path $PasswordFile) {
    # The file is ACL'd to read-only for SYSTEM/Administrators/task user
    # with inheritance disabled, so take ownership-equivalent rights back
    # before deleting or Remove-Item fails with "Access is denied".
    icacls $PasswordFile /reset 2>$null | Out-Null
    icacls $PasswordFile /grant:r "BUILTIN\Administrators:(F)" "SYSTEM:(F)" 2>$null | Out-Null
    try {
        Remove-Item -Path $PasswordFile -Force -ErrorAction Stop
        Write-Host "Password file deleted: $PasswordFile"
    } catch {
        Write-Host "Could not delete password file ${PasswordFile}: $_"
    }
} else {
    Write-Host "Password file not found, skipping: $PasswordFile"
}

# ---- Optional: full cleanup ----
if ($Full) {
    Write-Host ""
    Write-Host "--- Full cleanup (-Full) ---"
    $ScriptDest     = Join-Path $ConfigDir "sync-documents.ps1"
    $ExcludeFile    = Join-Path $ConfigDir "excludes.txt"
    $ExtraPathsFile = Join-Path $ConfigDir "extra-paths.txt"
    $LogFile        = Join-Path $ConfigDir "sync.log"
    foreach ($f in @($ScriptDest, $ExcludeFile, $ExtraPathsFile, $LogFile, "$LogFile.1")) {
        if (Test-Path $f) {
            try { Remove-Item -Path $f -Force -ErrorAction Stop; Write-Host "Deleted: $f" }
            catch { Write-Host "Could not delete ${f}: $_" }
        }
    }
    # Remove restic from PATH + disk
    $InstallDir = "C:\Program Files\restic"
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machinePath -like "*$InstallDir*") {
        $newPath = ($machinePath -split ";" | Where-Object { $_ -and $_ -ne $InstallDir }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Host "Removed $InstallDir from machine PATH."
    }
    if (Test-Path $InstallDir) {
        try { Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop; Write-Host "Deleted: $InstallDir" }
        catch { Write-Host "Could not delete ${InstallDir}: $_" }
    }
    if ((Test-Path $ConfigDir) -and -not (Get-ChildItem -Path $ConfigDir -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -Path $ConfigDir -Force -ErrorAction Stop; Write-Host "Deleted empty dir: $ConfigDir" }
        catch { Write-Host "Could not delete ${ConfigDir}: $_" }
    } else {
        Write-Host "Config dir kept (still contains files): $ConfigDir"
    }
}

Write-Host ""
Write-Host "=== Uninstall complete ==="
Write-Host "Removed: task '$TaskName', env keys ($($EnvVars -join ', ')), $PasswordFile"
if (-not $Full) {
    Write-Host "Kept: restic.exe, logs, excludes (re-run with -Full to remove those too)"
}
Write-Host "========================= End of uninstall-backup-agent ============================"
