<#
.SYNOPSIS
    Installer for Thetis QSO Recorder.

.DESCRIPTION
    Downloads the latest ThetisQSORecorder.ps1 from GitHub, unblocks it, and
    creates two Desktop shortcuts: one to run it, one to re-run its setup
    wizard (-Reconfigure). Also offers to install PowerShell 7 via winget if
    it isn't already present.

    Written to run on the Windows PowerShell 5.1 that ships with Windows by
    default -- so it works as a one-liner even before PowerShell 7 is
    installed:

        irm https://raw.githubusercontent.com/Chris-W4ORS/ThetisQSORecorder/main/Install.ps1 | iex

    Re-run this any time to update to the latest version of the script --
    your saved config (device choice, output folder, TCI host/port) is
    untouched, since that lives separately in %APPDATA%\ThetisQSORecorder\.
#>

param(
    [string]$InstallDir = "$env:LOCALAPPDATA\ThetisQSORecorder"
)

$ErrorActionPreference = "Stop"
$RepoRawUrl = "https://raw.githubusercontent.com/Chris-W4ORS/ThetisQSORecorder/main/ThetisQSORecorder.ps1"

Write-Host ""
Write-Host "=== Thetis QSO Recorder -- Installer ===" -ForegroundColor Cyan
Write-Host ""

# ── 1. PowerShell 7+ check ────────────────────────────────────────────────────
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd) {
    Write-Host "PowerShell 7 is required to run the recorder (you're currently running this installer on Windows PowerShell, which is fine just for installing)." -ForegroundColor Yellow
    $resp = Read-Host "Install PowerShell 7 now via winget? [Y/n]"
    if ($resp -notmatch '^(n|no)$') {
        try {
            winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements
            Write-Host "PowerShell 7 installed." -ForegroundColor Green
        } catch {
            Write-Warning "winget install failed ($($_.Exception.Message)). Install manually from https://aka.ms/powershell-release?tag=stable"
        }
    } else {
        Write-Warning "Skipping. Install PowerShell 7 manually before launching the recorder: https://aka.ms/powershell-release?tag=stable"
    }
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
} else {
    Write-Host "PowerShell 7 found: $($pwshCmd.Source)" -ForegroundColor Green
}

$pwshPath = if ($pwshCmd) { $pwshCmd.Source }
            elseif (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
            else { $null }

# ── 2. Download the script ────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$scriptPath = Join-Path $InstallDir "ThetisQSORecorder.ps1"
Write-Host ""
Write-Host "Downloading ThetisQSORecorder.ps1 to $scriptPath ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $RepoRawUrl -OutFile $scriptPath -UseBasicParsing
Unblock-File -Path $scriptPath
Write-Host "Done." -ForegroundColor Green

# ── 3. Desktop shortcuts ───────────────────────────────────────────────────────
$desktop = [Environment]::GetFolderPath("Desktop")
$wsh = New-Object -ComObject WScript.Shell

$shortcutPath = Join-Path $desktop "Thetis QSO Recorder.lnk"
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = if ($pwshPath) { $pwshPath } else { "pwsh.exe" }
$shortcut.Arguments  = "-NoExit -File `"$scriptPath`""
$shortcut.WorkingDirectory = $InstallDir
if ($pwshPath) { $shortcut.IconLocation = "$pwshPath,0" }
$shortcut.Description = "Thetis QSO Recorder"
$shortcut.Save()
Write-Host "Desktop shortcut created: $shortcutPath" -ForegroundColor Green

$reconfigShortcutPath = Join-Path $desktop "Thetis QSO Recorder (Reconfigure).lnk"
$reconfigShortcut = $wsh.CreateShortcut($reconfigShortcutPath)
$reconfigShortcut.TargetPath = if ($pwshPath) { $pwshPath } else { "pwsh.exe" }
$reconfigShortcut.Arguments  = "-NoExit -File `"$scriptPath`" -Reconfigure"
$reconfigShortcut.WorkingDirectory = $InstallDir
if ($pwshPath) { $reconfigShortcut.IconLocation = "$pwshPath,0" }
$reconfigShortcut.Description = "Re-run Thetis QSO Recorder setup (change mic device, output folder, or TCI connection)"
$reconfigShortcut.Save()
Write-Host "Reconfigure shortcut created: $reconfigShortcutPath" -ForegroundColor Green

Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Cyan
Write-Host "Double-click 'Thetis QSO Recorder' on your Desktop to launch it."
Write-Host "First launch walks you through a short one-time setup: pick your mic/TX capture"
Write-Host "device, confirm the recording folder, confirm Thetis's TCI connection."
Write-Host ""
Write-Host "Need to change any of that later? Use the second shortcut:"
Write-Host "'Thetis QSO Recorder (Reconfigure)' -- also created on your Desktop." -ForegroundColor Gray
Write-Host ""
Write-Host "Don't forget: Thetis's TCI server AND CAT (network) server both need to be enabled" -ForegroundColor Yellow
Write-Host "-- see the README for exact steps if you haven't done that yet." -ForegroundColor Yellow
Write-Host ""
