# hotshot Windows installer — copies the scripts to %LOCALAPPDATA%\Hotshot and
# creates a Start Menu shortcut with a global hotkey (default Ctrl+Alt+H).
#
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1 [-Hotkey 'Ctrl+Alt+H'] [-Uninstall]
[CmdletBinding()]
param(
    [string]$Hotkey = 'Ctrl+Alt+H',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'Hotshot'
$startMenu = [Environment]::GetFolderPath('StartMenu')
$shortcutPath = Join-Path $startMenu 'Programs\hotshot.lnk'
$scriptSrc = Join-Path $PSScriptRoot 'hotshot-capture.ps1'
$moduleSrc = Join-Path $PSScriptRoot 'HotshotCapture.psm1'

if ($Uninstall) {
    Remove-Item -Force -ErrorAction SilentlyContinue $shortcutPath
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $installDir
    Write-Host 'hotshot uninstalled.'
    exit 0
}

foreach ($src in @($scriptSrc, $moduleSrc)) {
    if (-not (Test-Path $src)) {
        Write-Error "install.ps1: $(Split-Path -Leaf $src) not found next to the installer ($src)"
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item -Force $scriptSrc, $moduleSrc $installDir
$ahkSrc = Join-Path $PSScriptRoot 'hotshot.ahk'
if (Test-Path $ahkSrc) { Copy-Item -Force $ahkSrc $installDir }

# A Start Menu shortcut's Hotkey property gives us a global hotkey with zero
# extra dependencies (Windows dispatches it to the shortcut's target).
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($shortcutPath)
$sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installDir\hotshot-capture.ps1`""
$sc.WorkingDirectory = $installDir
$sc.WindowStyle = 7   # minimized
$sc.Hotkey = $Hotkey
$sc.Description = 'hotshot — screenshot straight into your AI CLI'
$sc.Save()

Write-Host "Installed to:  $installDir"
Write-Host "Shortcut:      $shortcutPath"
Write-Host "Global hotkey: $Hotkey  (press it, snip a region, done)"
Write-Host ''
Write-Host 'Note: shortcut hotkeys can take a moment to launch. For an instant'
Write-Host 'response, install AutoHotkey v2 and run hotshot.ahk instead (it binds'
Write-Host 'Ctrl+Shift+PrintScreen). See windows\README.md.'
