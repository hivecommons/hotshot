# Pure helper functions for hotshot-capture.ps1.

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
        [bool]$Verbose = (Get-HotshotVerboseLogging)
    )
    if ($Verbose) { return $Path }
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

Export-ModuleMember -Function Get-TargetCli, Get-HotshotTypedText, ConvertTo-SendKeysEscaped, `
    Get-HotshotVerboseLogging, Get-RedactedPath, Format-HotshotDiagnostic
