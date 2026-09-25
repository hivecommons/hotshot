# hotshot for Windows — capture a screenshot, load the clipboard, and type the
# path into the focused terminal in the format its AI CLI understands.
#
# Behavior contract (parity with the macOS app):
#   1. Open the Snipping Tool region overlay (ms-screenclip:) and wait for the
#      captured image to land on the clipboard.
#   2. Save it as a PNG and rewrite the clipboard with a single multi-format
#      entry: the image (CF_BITMAP/PNG), the plain-text path (CF_UNICODETEXT),
#      and a file drop list (the Explorer-copy equivalent of macOS' file URL).
#   3. Detect which AI CLI runs in the terminal that was focused before the
#      overlay (walking its child processes), refocus it, and type:
#        claude                     -> "[path] "  (bracketed)
#        copilot / aider / opencode -> path (double-quoted if it has spaces) + " "
#        unknown                    -> "[path] "  (historical default)
#
# Usage: powershell -ExecutionPolicy Bypass -File hotshot-capture.ps1 [-NoType] [-Dir <folder>]
[CmdletBinding()]
param(
    [switch]$NoType,
    [string]$Dir = "$(if ($env:HOTSHOT_DIR) { $env:HOTSHOT_DIR } else { Join-Path ([Environment]::GetFolderPath('MyPictures')) 'hotshot' })"
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HotshotCapture.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace Hotshot -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
'@

function Fail([string]$msg) {
    Write-Error "hotshot: $msg" -ErrorAction Continue
    exit 1
}

# --- 0. remember the focused terminal BEFORE the capture overlay -------------
$termHwnd = [Hotshot.Native]::GetForegroundWindow()
$termPid = [uint32]0
[void][Hotshot.Native]::GetWindowThreadProcessId($termHwnd, [ref]$termPid)

# --- 1. capture via the Snipping Tool overlay ---------------------------------
$seqBefore = [Hotshot.Native]::GetClipboardSequenceNumber()
Start-Process 'ms-screenclip:'   # Snipping overlay; result lands on the clipboard

$img = $null
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if ([Hotshot.Native]::GetClipboardSequenceNumber() -ne $seqBefore) {
        if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
            $img = [System.Windows.Forms.Clipboard]::GetImage()
            if ($img) { break }
        }
    }
}
if (-not $img) { Fail 'capture cancelled or timed out (no image appeared on the clipboard)' }

# --- 2. save PNG + multi-format clipboard -------------------------------------
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$shotPath = Join-Path $Dir ("hotshot-{0:yyyyMMdd-HHmmss}.png" -f (Get-Date))
$img.Save($shotPath, [System.Drawing.Imaging.ImageFormat]::Png)

$dataObj = New-Object System.Windows.Forms.DataObject
$dataObj.SetImage($img)
$dataObj.SetText($shotPath)
$files = New-Object System.Collections.Specialized.StringCollection
[void]$files.Add($shotPath)
$dataObj.SetFileDropList($files)
try {
    [System.Windows.Forms.Clipboard]::SetDataObject($dataObj, $true)
} catch {
    Write-Warning "hotshot: could not rewrite the clipboard: $_"
}

# --- 3. CLI detection ----------------------------------------------------------
$cli = Get-TargetCli $termPid

$text = Get-HotshotTypedText -ShotPath $shotPath -Cli $cli

# --- 4. typed injection ---------------------------------------------------------
if (-not $NoType) {
    if ($termHwnd -ne [IntPtr]::Zero) {
        [void][Hotshot.Native]::SetForegroundWindow($termHwnd)
        Start-Sleep -Milliseconds 300
        $escaped = ConvertTo-SendKeysEscaped -Text $text
        try {
            [System.Windows.Forms.SendKeys]::SendWait($escaped)
        } catch {
            Write-Warning "hotshot: failed to type into the terminal: $_ (path: $shotPath)"
        }
    } else {
        Write-Warning "hotshot: no foreground terminal was recorded; path is $shotPath"
    }
}

Write-Output $shotPath
