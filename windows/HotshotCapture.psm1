# Helper functions for hotshot-capture.ps1. Side-effecting collaborators
# (clipboard, Win32, SendKeys, sleeps) are scriptblock parameters that default
# to the real calls so tests can substitute them.

if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    function Get-CimInstance {
        param([Parameter(ValueFromRemainingArguments)] [object[]]$ArgumentList)
        throw 'Get-CimInstance is not available in this PowerShell session.'
    }
}

function Get-TargetCli {
    [CmdletBinding()]
    param([uint32]$RootPid)

    if (-not $RootPid) { return 'unknown' }
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId, Name, CommandLine
    if (-not $all) { return 'unknown' }
    $byParent = $all | Group-Object ParentProcessId -AsHashTable -AsString

    $sawPlain = $false
    $queue = [System.Collections.Generic.Queue[uint32]]::new()
    $queue.Enqueue($RootPid)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $p = $queue.Dequeue()
        if ($seen.ContainsKey($p)) { continue }
        $seen[$p] = $true
        $proc = $all | Where-Object { $_.ProcessId -eq $p }
        foreach ($pr in $proc) {
            $name = if ($pr.Name) { $pr.Name.ToLower() } else { '' }
            $cmd = if ($pr.CommandLine) { $pr.CommandLine.ToLower() } else { '' }
            if ($name -eq 'claude.exe' -or $cmd -match '[\\/ "]claude(-code)?(\.\w+)?("|[\\/ ]|$)') { return 'claude' }
            if ($name -in @('copilot.exe', 'aider.exe', 'opencode.exe') -or
                $cmd -match '[\\/ "](copilot|aider|opencode)(\.\w+)?("|[\\/ ]|$)') { $sawPlain = $true }
        }
        $kids = $byParent["$p"]
        if ($kids) { foreach ($k in $kids) { $queue.Enqueue([uint32]$k.ProcessId) } }
    }
    if ($sawPlain) { return 'plain' } else { return 'unknown' }
}

function Get-HotshotTypedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ShotPath,
        [Parameter(Mandatory)] [ValidateSet('claude', 'plain', 'unknown')] [string]$Cli
    )

    # Parity with the macOS app (HotshotCore.containsControlCharacters): a
    # CR/LF in the path would press Enter mid-string via SendKeys, so paths
    # containing control characters are never typed.
    if ($ShotPath -match '[\x00-\x1F\x7F\u2028\u2029]') { return '' }

    switch ($Cli) {
        'plain' {
            # Windows shells take a double-quoted path; quote only when needed.
            if ($ShotPath -match '[\s]') { return '"' + $ShotPath + '" ' }
            return $ShotPath + ' '
        }
        default { return "[$ShotPath] " }
    }
}

function ConvertTo-SendKeysEscaped {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)

    return ($Text.ToCharArray() | ForEach-Object {
            if ($_ -in '+', '^', '%', '~', '(', ')', '{', '}', '[', ']') { "{$_}" } else { "$_" }
        }) -join ''
}

# --- Diagnostic logging (issue #77) -------------------------------------------
# Normal diagnostics must never contain screenshot directory paths,
# filenames, generated scripts, or clipboard contents. Set
# HOTSHOT_VERBOSE_LOGGING=1 to opt into raw values for local debugging; this
# stays local-only (no exporter or network flow).

function Get-HotshotVerboseLogging {
    [CmdletBinding()]
    param()
    return $env:HOTSHOT_VERBOSE_LOGGING -eq '1'
}

function Get-RedactedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Path,
        [bool]$VerboseLogging = (Get-HotshotVerboseLogging)
    )
    if ($VerboseLogging) { return $Path }
    return '<redacted>'
}

function Format-HotshotDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Severity,
        [Parameter(Mandatory)] [string]$Event,
        [string]$Detail
    )
    if ($Detail) { return "hotshot [$Severity] ${Event}: $Detail" }
    return "hotshot [$Severity] $Event"
}

# --- Capture orchestration (issue #129) -------------------------------------
# The [Hotshot.Native] defaults rely on the Add-Type in hotshot-capture.ps1.

function Wait-HotshotClipboardImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uint32]$SequenceBefore,
        [Parameter(Mandatory)] [datetime]$Deadline,
        [scriptblock]$GetSequence = { [Hotshot.Native]::GetClipboardSequenceNumber() },
        [scriptblock]$ContainsImage = { [System.Windows.Forms.Clipboard]::ContainsImage() },
        [scriptblock]$GetImage = { [System.Windows.Forms.Clipboard]::GetImage() },
        [scriptblock]$Sleep = { Start-Sleep -Milliseconds 250 },
        [scriptblock]$Now = { Get-Date }
    )

    while ((& $Now) -lt $Deadline) {
        & $Sleep
        if ((& $GetSequence) -ne $SequenceBefore) {
            if (& $ContainsImage) {
                $img = & $GetImage
                if ($img) { return $img }
            }
        }
    }
    return $null
}

function Get-HotshotShotPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Dir,
        [datetime]$Timestamp = (Get-Date)
    )
    return Join-Path $Dir ("hotshot-{0:yyyyMMdd-HHmmss}.png" -f $Timestamp)
}

function New-HotshotClipboardDataObject {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object; no system state changes.')]
    param(
        [Parameter(Mandatory)] [object]$Image,
        [Parameter(Mandatory)] [string]$ShotPath
    )

    $dataObj = New-Object System.Windows.Forms.DataObject
    $dataObj.SetImage($Image)
    $dataObj.SetText($ShotPath)
    $files = New-Object System.Collections.Specialized.StringCollection
    [void]$files.Add($ShotPath)
    $dataObj.SetFileDropList($files)
    return $dataObj
}

function Set-HotshotClipboardDataObject {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Interactive clipboard rewrite; failures only warn.')]
    param(
        [Parameter(Mandatory)] [object]$DataObject,
        [scriptblock]$SetDataObject = { param($o) [System.Windows.Forms.Clipboard]::SetDataObject($o, $true) }
    )

    try {
        & $SetDataObject $DataObject
    } catch {
        Write-Warning "hotshot: could not rewrite the clipboard: $_"
    }
}

function Invoke-HotshotInjection {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$Text,
        [IntPtr]$TerminalHandle = [IntPtr]::Zero,
        [switch]$NoType,
        [Parameter(Mandatory)] [string]$ShotPath,
        [scriptblock]$SetForeground = { param($h) [void][Hotshot.Native]::SetForegroundWindow($h) },
        [scriptblock]$SendKeys = { param($k) [System.Windows.Forms.SendKeys]::SendWait($k) },
        [scriptblock]$Sleep = { Start-Sleep -Milliseconds 300 }
    )

    $verboseLogging = Get-HotshotVerboseLogging
    if ($NoType) { return }
    if (-not $Text) {
        Write-Warning (Format-HotshotDiagnostic -Severity WARN -Event 'injection.control_chars_refused' `
                -Detail "path=$(Get-RedactedPath -Path $ShotPath -VerboseLogging $verboseLogging)")
    } elseif ($TerminalHandle -ne [IntPtr]::Zero) {
        [void](& $SetForeground $TerminalHandle)
        & $Sleep
        $escaped = ConvertTo-SendKeysEscaped -Text $Text
        try {
            & $SendKeys $escaped
        } catch {
            Write-Warning (Format-HotshotDiagnostic -Severity WARN -Event 'injection.sendkeys_failed' -Detail "$_")
        }
    } else {
        Write-Warning (Format-HotshotDiagnostic -Severity WARN -Event 'injection.no_foreground_terminal')
    }
}

Export-ModuleMember -Function Get-TargetCli, Get-HotshotTypedText, ConvertTo-SendKeysEscaped, `
    Get-HotshotVerboseLogging, Get-RedactedPath, Format-HotshotDiagnostic, `
    Wait-HotshotClipboardImage, Get-HotshotShotPath, New-HotshotClipboardDataObject, `
    Set-HotshotClipboardDataObject, Invoke-HotshotInjection
