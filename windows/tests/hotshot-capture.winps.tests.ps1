# Windows PowerShell 5.1 compatibility tests.
#
# Both production launchers start hotshot-capture.ps1 with powershell.exe
# (Windows PowerShell 5.1, .NET Framework): the Start Menu shortcut that
# install.ps1 creates targets System32\WindowsPowerShell\v1.0\powershell.exe,
# and hotshot.ahk runs `powershell.exe -File hotshot-capture.ps1`. Every other
# suite here runs under pwsh 7 (.NET), so a pwsh-only construct (`??`, `?.`,
# the ternary, three-argument Join-Path, ...) or a .NET Framework behaviour
# difference in the module, the entry script or the installer would pass CI
# and break the installed product.
#
# This suite re-runs the real files in a child powershell.exe:
#   - HotshotCapture.psm1: the pure functions, compared against the same calls
#     made in this (pwsh) host, plus the Windows.Forms clipboard data object;
#   - hotshot-capture.ps1: against a recording stub module, the same way
#     hotshot-capture.e2e.tests.ps1 does under pwsh;
#   - install.ps1: install and -Uninstall against a redirected LOCALAPPDATA.
#
# Child code is written to .ps1 files and run with -File: Windows PowerShell's
# -Command argument parsing strips embedded double quotes, so a -Command string
# would need host-specific escaping. The whole suite is skipped where
# powershell.exe is absent (non-Windows hosts).

$script:WinPS = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue

BeforeAll {
    $script:ModuleSrc = Join-Path $PSScriptRoot '..' 'HotshotCapture.psm1'
    $script:CaptureSrc = Join-Path $PSScriptRoot '..' 'hotshot-capture.ps1'
    $script:InstallerSrc = Join-Path $PSScriptRoot '..' 'install.ps1'
    Import-Module $script:ModuleSrc -Force

    # Runs a script file in a child Windows PowerShell and returns its exit
    # code, stdout lines and stderr text.
    function Invoke-WinPS {
        param([Parameter(Mandatory)] [string]$File, [string[]]$Arguments = @())
        $stderrFile = Join-Path $script:TempRoot ('stderr-' + [guid]::NewGuid() + '.txt')
        $stdout = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $File @Arguments 2>$stderrFile
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Stdout   = @($stdout | ForEach-Object { "$_" })
            Stderr   = (Get-Content -Raw -ErrorAction SilentlyContinue $stderrFile)
        }
    }

    # Exercises the module's pure functions and prints one JSON object. Every
    # value here is also computed in the pwsh host (see 'module functions')
    # and the two must agree.
    $script:ModuleProbe = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'   # warnings are asserted via -WarningVariable, not stdout
Remove-Item Env:HOTSHOT_VERBOSE_LOGGING -ErrorAction SilentlyContinue
Set-Location $env:HOTSHOT_TEST_CWD
Import-Module $env:HOTSHOT_TEST_MODULE -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$r = [ordered]@{}
$r.psMajor = $PSVersionTable.PSVersion.Major
$r.cwd = (Get-Location).ProviderPath
$r.typedClaude = Get-HotshotTypedText -ShotPath 'C:\Shots\a b.png' -Cli claude
$r.typedPlainSpace = Get-HotshotTypedText -ShotPath 'C:\Shots\a b.png' -Cli plain
$r.typedPlain = Get-HotshotTypedText -ShotPath 'C:\Shots\a.png' -Cli plain
$r.typedUnknown = Get-HotshotTypedText -ShotPath 'C:\Shots\a.png' -Cli unknown
$r.typedControl = Get-HotshotTypedText -ShotPath "C:\Shots\a`n.png" -Cli claude
$r.typedMeta = Get-HotshotTypedText -ShotPath 'C:\Shots\a&calc.png' -Cli claude
$r.typedQuote = Get-HotshotTypedText -ShotPath 'C:\Shots\a"b.png' -Cli plain
$r.sendKeys = ConvertTo-SendKeysEscaped -Text '[C:\a+b (1)] {x}~^%'
$r.redacted = Get-RedactedPath -Path 'C:\Shots\secret.png' -VerboseLogging $false
$r.revealed = Get-RedactedPath -Path 'C:\Shots\secret.png' -VerboseLogging $true
$r.diag = Format-HotshotDiagnostic -Severity WARN -Event 'injection.focus_lost' -Detail 'SetForegroundWindow=False'
$r.diagNoDetail = Format-HotshotDiagnostic -Severity INFO -Event 'capture.saved'
$r.resolveTilde = Resolve-HotshotDirectory -Dir '~\shots'
$r.resolveRelative = Resolve-HotshotDirectory -Dir 'rel\shots'
$r.resolveAbsolute = Resolve-HotshotDirectory -Dir 'C:\Shots\..\Other\'
$ts = New-Object datetime 2026, 1, 2, 3, 4, 5, 678
$r.shotFree = Get-HotshotShotPath -Dir 'C:\Shots' -Timestamp $ts -Exists { param($p) $false }
$r.shotTaken = Get-HotshotShotPath -Dir 'C:\Shots' -Timestamp $ts -Exists { param($p) $p -notmatch '-2\.png$' }
$rn = 0
$r.shotReserve = Get-HotshotShotPath -Dir 'C:\Shots' -Timestamp $ts -Reserve { param($p) $script:rn++; $script:rn -gt 1 }

$r.waitImage = Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline (Get-Date).AddMinutes(5) `
    -GetSequence { 8 } -ContainsImage { $true } -GetImage { 'stub-image' } -Sleep { }
$r.waitExpired = $null -eq (Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline (Get-Date).AddMinutes(-1) -Sleep { })

$sent = New-Object System.Collections.ArrayList
$hwnd = [IntPtr]42
Invoke-HotshotInjection -Text '[C:\a+b.png] ' -TerminalHandle $hwnd -ShotPath 'C:\a+b.png' `
    -SetForeground { param($h) $true } -GetForeground { [IntPtr]42 } -SendKeys { param($k) [void]$sent.Add($k) } -Sleep { }
$r.injected = @($sent) -join '|'
Invoke-HotshotInjection -Text '[C:\a.png] ' -TerminalHandle $hwnd -ShotPath 'C:\a.png' -WarningVariable focusWarnings `
    -SetForeground { param($h) $false } -GetForeground { [IntPtr]7 } -SendKeys { param($k) [void]$sent.Add($k) } -Sleep { }
$r.focusLost = @($focusWarnings | ForEach-Object { "$_" }) -join '|'
$r.injectedAfterFocusLost = $sent.Count
Invoke-HotshotInjection -Text '' -TerminalHandle $hwnd -ShotPath 'C:\a&calc.png' -WarningVariable refusalWarnings `
    -SendKeys { param($k) [void]$sent.Add($k) } -Sleep { }
$r.metaRefused = @($refusalWarnings | ForEach-Object { "$_" }) -join '|'
Invoke-HotshotInjection -Text '[C:\a.png] ' -ShotPath 'C:\a.png' -WarningVariable noTerminalWarnings -Sleep { }
$r.noTerminal = @($noTerminalWarnings | ForEach-Object { "$_" }) -join '|'

$bitmap = New-Object System.Drawing.Bitmap 1, 1
$dataObj = New-HotshotClipboardDataObject -Image $bitmap -ShotPath 'C:\Shots\clip.png'
$r.clipText = $dataObj.GetText()
$r.clipHasImage = $dataObj.ContainsImage()
$r.clipFiles = @($dataObj.GetFileDropList()) -join '|'
Set-HotshotClipboardDataObject -DataObject $dataObj -SetDataObject { param($o) throw 'boom' } -WarningVariable clipWarnings
$r.clipFailure = @($clipWarnings | ForEach-Object { "$_" }) -join '|'

$r | ConvertTo-Json -Compress
'@

    # Stub HotshotCapture.psm1 for the entry-script run: same exported surface,
    # no clipboard, Win32 or SendKeys side effects. Appends one call name per
    # line to $env:HOTSHOT_TEST_LOG; HOTSHOT_TEST_IMAGE=1 makes the clipboard
    # wait return a fake image whose Save() writes a marker file.
    $script:StubModule = @'
function Write-StubCall { param([string]$Function) Add-Content -Path $env:HOTSHOT_TEST_LOG -Value $Function }

function Wait-HotshotClipboardImage {
    param([uint32]$SequenceBefore, [datetime]$Deadline)
    Write-StubCall 'Wait-HotshotClipboardImage'
    if ($env:HOTSHOT_TEST_IMAGE -ne '1') { return $null }
    $img = New-Object psobject
    $img | Add-Member -MemberType ScriptMethod -Name Save -Value {
        param($Path, $Format)
        Set-Content -Path $Path -Value 'stub-png'
        Write-StubCall 'Image.Save'
    }
    return $img
}
function Resolve-HotshotDirectory { param([string]$Dir) return $Dir }
function Get-HotshotShotPath { param([string]$Dir) Write-StubCall 'Get-HotshotShotPath'; return (Join-Path $Dir 'hotshot-stub.png') }
function New-HotshotClipboardDataObject { param([object]$Image, [string]$ShotPath) Write-StubCall 'New-HotshotClipboardDataObject'; return $ShotPath }
function Set-HotshotClipboardDataObject { param([object]$DataObject) Write-StubCall 'Set-HotshotClipboardDataObject' }
function Get-TargetCli { param([uint32]$RootPid) Write-StubCall 'Get-TargetCli'; return 'claude' }
function Get-HotshotTypedText { param([string]$ShotPath, [string]$Cli) Write-StubCall 'Get-HotshotTypedText'; return "[$ShotPath] " }
function Invoke-HotshotInjection {
    param([string]$Text, [IntPtr]$TerminalHandle, [switch]$NoType, [string]$ShotPath)
    Write-StubCall 'Invoke-HotshotInjection'
    Add-Content -Path $env:HOTSHOT_TEST_LOG -Value "typed:$Text"
}
Export-ModuleMember -Function Wait-HotshotClipboardImage, Resolve-HotshotDirectory, Get-HotshotShotPath, `
    New-HotshotClipboardDataObject, Set-HotshotClipboardDataObject, Get-TargetCli, `
    Get-HotshotTypedText, Invoke-HotshotInjection
'@

    # Driver for the entry script: shadows Start-Process (functions win over
    # cmdlets in child scopes) so the Snipping Tool overlay is never launched,
    # then runs the script and propagates its exit code.
    $script:CaptureDriver = @'
function Start-Process {
    param([Parameter(Position = 0)] [string]$FilePath, [Parameter(ValueFromRemainingArguments)] [object[]]$Rest)
    Add-Content -Path $env:HOTSHOT_TEST_LOG -Value "Start-Process:$FilePath"
}
& $env:HOTSHOT_TEST_SCRIPT -Dir $env:HOTSHOT_TEST_DIR
exit $LASTEXITCODE
'@

    function Read-StubCallLog {
        if (-not (Test-Path $env:HOTSHOT_TEST_LOG)) { return @() }
        @(Get-Content $env:HOTSHOT_TEST_LOG | Where-Object { $_ })
    }
}

Describe 'Windows PowerShell 5.1 compatibility' -Skip:(-not $script:WinPS) {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hotshot-winps-tests-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:TempRoot
    }

    Context 'HotshotCapture.psm1 module functions' {
        BeforeEach {
            $probe = Join-Path $script:TempRoot 'probe.ps1'
            Set-Content -Path $probe -Value $script:ModuleProbe
            $env:HOTSHOT_TEST_MODULE = $script:ModuleSrc
            $env:HOTSHOT_TEST_CWD = $script:TempRoot
            $script:Result = Invoke-WinPS -File $probe
            $script:Got = if ($script:Result.ExitCode -eq 0) { $script:Result.Stdout[-1] | ConvertFrom-Json } else { $null }
        }

        AfterEach {
            Remove-Item Env:HOTSHOT_TEST_MODULE, Env:HOTSHOT_TEST_CWD -ErrorAction SilentlyContinue
        }

        It 'imports and runs under Windows PowerShell 5' {
            $script:Result.ExitCode | Should -Be 0 -Because $script:Result.Stderr
            $script:Got.psMajor | Should -Be 5
        }

        It 'types the same text for every CLI as the pwsh host does' {
            $script:Got.typedClaude | Should -Be (Get-HotshotTypedText -ShotPath 'C:\Shots\a b.png' -Cli claude)
            $script:Got.typedPlainSpace | Should -Be (Get-HotshotTypedText -ShotPath 'C:\Shots\a b.png' -Cli plain)
            $script:Got.typedPlain | Should -Be (Get-HotshotTypedText -ShotPath 'C:\Shots\a.png' -Cli plain)
            $script:Got.typedUnknown | Should -Be (Get-HotshotTypedText -ShotPath 'C:\Shots\a.png' -Cli unknown)
            $script:Got.typedClaude | Should -Be '[C:\Shots\a b.png] '
            $script:Got.typedPlainSpace | Should -Be '"C:\Shots\a b.png" '
        }

        It 'refuses control characters, metacharacters and quotes exactly as the pwsh host does' {
            $script:Got.typedControl | Should -Be ''
            $script:Got.typedMeta | Should -Be ''
            $script:Got.typedQuote | Should -Be ''
            $script:Got.typedControl | Should -Be (Get-HotshotTypedText -ShotPath "C:\Shots\a`n.png" -Cli claude)
        }

        It 'escapes SendKeys specials, redacts paths and formats diagnostics identically' {
            $script:Got.sendKeys | Should -Be (ConvertTo-SendKeysEscaped -Text '[C:\a+b (1)] {x}~^%')
            $script:Got.sendKeys | Should -Be '{[}C:\a{+}b {(}1{)}{]} {{}x{}}{~}{^}{%}'
            $script:Got.redacted | Should -Be '<redacted>'
            $script:Got.revealed | Should -Be 'C:\Shots\secret.png'
            $script:Got.diag | Should -Be 'hotshot [WARN] injection.focus_lost: SetForegroundWindow=False'
            $script:Got.diagNoDetail | Should -Be 'hotshot [INFO] capture.saved'
        }

        It 'resolves ~, relative and absolute directories to the same full paths' {
            $script:Got.resolveTilde | Should -Be ([IO.Path]::GetFullPath((Join-Path $HOME 'shots')))
            # Anchored to the child's own cwd: the temp path may be an 8.3 short
            # name there, so compare against what the child saw rather than $script:TempRoot.
            $script:Got.resolveRelative | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:Got.cwd 'rel\shots')))
            $script:Got.resolveRelative | Should -Not -Be ([IO.Path]::GetFullPath('rel\shots'))
            $script:Got.resolveAbsolute | Should -Be 'C:\Other\'
            $script:Got.resolveAbsolute | Should -Be (Resolve-HotshotDirectory -Dir 'C:\Shots\..\Other\')
        }

        It 'names screenshots with the millisecond timestamp and -N suffix' {
            $script:Got.shotFree | Should -Be 'C:\Shots\hotshot-20260102-030405-678.png'
            $script:Got.shotTaken | Should -Be 'C:\Shots\hotshot-20260102-030405-678-2.png'
            $script:Got.shotReserve | Should -Be 'C:\Shots\hotshot-20260102-030405-678-1.png'
        }

        It 'polls the clipboard through the injected collaborators' {
            $script:Got.waitImage | Should -Be 'stub-image'
            $script:Got.waitExpired | Should -BeTrue
        }

        It 'refocuses and types through SendKeys, and warns instead of typing when focus is lost' {
            $script:Got.injected | Should -Be '{[}C:\a{+}b.png{]} '
            $script:Got.focusLost | Should -Match 'injection\.focus_lost'
            $script:Got.focusLost | Should -Match 'SetForegroundWindow=False'
            $script:Got.injectedAfterFocusLost | Should -Be 1
        }

        It 'warns with redacted paths for refused text and for a missing terminal' {
            $script:Got.metaRefused | Should -Match 'injection\.shell_metachars_refused'
            $script:Got.metaRefused | Should -Match 'path=<redacted>'
            $script:Got.metaRefused | Should -Not -Match 'calc'
            $script:Got.noTerminal | Should -Match 'injection\.no_foreground_terminal'
        }

        It 'builds the multi-format clipboard object on .NET Framework Windows.Forms' {
            $script:Got.clipText | Should -Be 'C:\Shots\clip.png'
            $script:Got.clipHasImage | Should -BeTrue
            $script:Got.clipFiles | Should -Be 'C:\Shots\clip.png'
            $script:Got.clipFailure | Should -Match 'could not rewrite the clipboard: boom'
        }
    }

    Context 'hotshot-capture.ps1 entry script' {
        BeforeEach {
            Copy-Item $script:CaptureSrc (Join-Path $script:TempRoot 'hotshot-capture.ps1')
            Set-Content -Path (Join-Path $script:TempRoot 'HotshotCapture.psm1') -Value $script:StubModule
            $script:Driver = Join-Path $script:TempRoot 'driver.ps1'
            Set-Content -Path $script:Driver -Value $script:CaptureDriver
            $script:ShotDir = Join-Path $script:TempRoot 'shots'   # must not pre-exist
            $script:ExpectedShot = Join-Path $script:ShotDir 'hotshot-stub.png'
            $env:HOTSHOT_TEST_SCRIPT = Join-Path $script:TempRoot 'hotshot-capture.ps1'
            $env:HOTSHOT_TEST_LOG = Join-Path $script:TempRoot 'calls.log'
            $env:HOTSHOT_TEST_DIR = $script:ShotDir
        }

        AfterEach {
            Remove-Item Env:HOTSHOT_TEST_SCRIPT, Env:HOTSHOT_TEST_LOG, Env:HOTSHOT_TEST_DIR, Env:HOTSHOT_TEST_IMAGE -ErrorAction SilentlyContinue
        }

        It 'captures, saves, loads the clipboard and injects in contract order' {
            $env:HOTSHOT_TEST_IMAGE = '1'
            $result = Invoke-WinPS -File $script:Driver

            $result.ExitCode | Should -Be 0 -Because $result.Stderr
            $result.Stdout[-1] | Should -Be $script:ExpectedShot
            Test-Path -PathType Leaf $script:ExpectedShot | Should -BeTrue
            Read-StubCallLog | Should -Be @(
                'Start-Process:ms-screenclip:', 'Wait-HotshotClipboardImage', 'Get-HotshotShotPath', 'Image.Save',
                'New-HotshotClipboardDataObject', 'Set-HotshotClipboardDataObject',
                'Get-TargetCli', 'Get-HotshotTypedText', 'Invoke-HotshotInjection', "typed:[$script:ExpectedShot] "
            )
        }

        It 'exits 1 with a hotshot-prefixed error when the capture is cancelled' {
            $result = Invoke-WinPS -File $script:Driver   # no image

            $result.ExitCode | Should -Be 1
            $result.Stderr | Should -Match 'hotshot: capture cancelled or timed out'
            Test-Path $script:ShotDir | Should -BeFalse
            Read-StubCallLog | Should -Be @('Start-Process:ms-screenclip:', 'Wait-HotshotClipboardImage')
        }
    }

    Context 'install.ps1 installer' {
        BeforeEach {
            $script:OrigLocalAppData = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = $script:TempRoot
            $script:InstallDir = Join-Path $script:TempRoot 'Hotshot'
            $script:ShortcutPath = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\hotshot.lnk'
            Remove-Item -Force -ErrorAction SilentlyContinue $script:ShortcutPath
        }

        AfterEach {
            Remove-Item -Force -ErrorAction SilentlyContinue $script:ShortcutPath
            $env:LOCALAPPDATA = $script:OrigLocalAppData
        }

        It 'installs the scripts and a shortcut that targets Windows PowerShell, then uninstalls cleanly' {
            $install = Invoke-WinPS -File $script:InstallerSrc

            $install.ExitCode | Should -Be 0 -Because $install.Stderr
            Join-Path $script:InstallDir 'hotshot-capture.ps1' | Should -Exist
            Join-Path $script:InstallDir 'HotshotCapture.psm1' | Should -Exist
            Join-Path $script:InstallDir 'hotshot.ahk' | Should -Exist
            $script:ShortcutPath | Should -Exist
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($script:ShortcutPath)
            $shortcut.TargetPath | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
            $shortcut.Arguments | Should -Match ([regex]::Escape((Join-Path $script:InstallDir 'hotshot-capture.ps1')))

            $uninstall = Invoke-WinPS -File $script:InstallerSrc -Arguments '-Uninstall'

            $uninstall.ExitCode | Should -Be 0 -Because $uninstall.Stderr
            $uninstall.Stdout -join "`n" | Should -Match 'hotshot uninstalled'
            Test-Path $script:InstallDir | Should -BeFalse
            Test-Path $script:ShortcutPath | Should -BeFalse
        }
    }
}
