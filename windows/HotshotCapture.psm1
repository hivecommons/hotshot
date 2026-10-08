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

# Parity with macOS SHELL_COMMAND_METACHARACTERS and linux has_shell_metachars.
function Test-HotshotShellMetacharacters {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    return ($Path -match '[$`;|&<>!]')
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
            # Double-quoting cannot protect a literal quote, and PowerShell
            # still interpolates `$(...)`/`$var` and backtick escapes inside a
            # double-quoted string, so refuse those (as the bracketed form
            # refuses metacharacters).
            if ($ShotPath -match '["$`]') { return '' }
            # Windows shells take a double-quoted path; quote whenever it has
            # whitespace or a shell metacharacter.
            if ($ShotPath -match '[\s&;|<>!()^%]') { return '"' + $ShotPath + '" ' }
            return $ShotPath + ' '
        }
        default {
            # The bracketed form is typed verbatim into an unknown shell, so it
            # is refused for shell command metacharacters (the plain form
            # double-quotes them instead, and refuses only a literal quote and
            # the characters PowerShell interpolates inside double quotes).
            if (Test-HotshotShellMetacharacters -Path $ShotPath) { return '' }
            return "[$ShotPath] "
        }
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
        [datetime]$Timestamp = (Get-Date),
        [scriptblock]$Exists = { param($p) Test-Path -LiteralPath $p }
    )
    # Millisecond timestamp plus a -N suffix when the name is already taken,
    # so two captures in the same instant never overwrite each other (parity
    # with the macOS app and the Linux port).
    $base = "hotshot-{0:yyyyMMdd-HHmmss-fff}" -f $Timestamp
    $path = Join-Path $Dir "$base.png"
    $n = 1
    while (& $Exists $path) {
        $path = Join-Path $Dir "$base-$n.png"
        $n++
    }
    return $path
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
        [scriptblock]$SetForeground = { param($h) [Hotshot.Native]::SetForegroundWindow($h) },
        [scriptblock]$GetForeground = { [Hotshot.Native]::GetForegroundWindow() },
        [scriptblock]$SendKeys = { param($k) [System.Windows.Forms.SendKeys]::SendWait($k) },
        [scriptblock]$Sleep = { Start-Sleep -Milliseconds 300 }
    )

    $verboseLogging = Get-HotshotVerboseLogging
    if ($NoType) { return }
    if (-not $Text) {
        $refusal = 'injection.control_chars_refused'
        if ($ShotPath -notmatch '[\x00-\x1F\x7F\u2028\u2029]' -and (Test-HotshotShellMetacharacters -Path $ShotPath)) {
            $refusal = 'injection.shell_metachars_refused'
        }
        Write-Warning (Format-HotshotDiagnostic -Severity WARN -Event $refusal `
                -Detail "path=$(Get-RedactedPath -Path $ShotPath -VerboseLogging $verboseLogging)")
    } elseif ($TerminalHandle -ne [IntPtr]::Zero) {
        $refocused = & $SetForeground $TerminalHandle
        & $Sleep
        # SetForegroundWindow can be refused (foreground lock, UIPI) and focus
        # can move during the sleep; never type into some other window. The
        # screenshot is already saved and on the clipboard.
        $foreground = & $GetForeground
        if ($null -eq $foreground -or [IntPtr]$foreground -ne $TerminalHandle) {
            Write-Warning (Format-HotshotDiagnostic -Severity WARN -Event 'injection.focus_lost' `
                    -Detail "SetForegroundWindow=$([bool]$refocused); screenshot saved and on the clipboard")
            return
        }
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
