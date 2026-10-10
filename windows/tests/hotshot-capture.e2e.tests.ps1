# End-to-end tests for the hotshot-capture.ps1 entry script. The module
# functions it calls are unit-tested in hotshot-capture.tests.ps1; this suite
# checks the script's own wiring - parameter defaults, the order of the
# capture steps, which value flows into which call, and the failure exits -
# by running the real script against a recording stub of HotshotCapture.psm1.
#
# Every run copies the script next to the stub module in a per-test temp
# directory (the script imports the module relative to $PSScriptRoot) and
# shadows Start-Process with a recording function so the Snipping Tool is
# never launched. Each stub appends one JSON line per call to
# $env:HOTSHOT_TEST_LOG; the tests read that log back.
#
# The script calls `exit`, so it must always run in a child pwsh process -
# never dot-sourced or &-invoked - or a failure path would kill the test host.

BeforeAll {
    $script:CaptureSrc = Join-Path $PSScriptRoot '..' 'hotshot-capture.ps1'

    # Stub module: same exported surface as HotshotCapture.psm1, no side
    # effects. Behaviour is steered by env vars:
    #   HOTSHOT_TEST_IMAGE  '1' -> the clipboard wait returns a fake image whose
    #                             Save() writes a marker file; unset -> $null
    #   HOTSHOT_TEST_CLI    value Get-TargetCli returns
    $script:StubModule = @'
function Write-StubCall {
    param([string]$Function, [hashtable]$Arguments)
    $record = @{ fn = $Function } + $Arguments
    Add-Content -Path $env:HOTSHOT_TEST_LOG -Value ($record | ConvertTo-Json -Compress -Depth 3)
}

function Wait-HotshotClipboardImage {
    param([uint32]$SequenceBefore, [datetime]$Deadline)
    Write-StubCall 'Wait-HotshotClipboardImage' @{
        SequenceBefore = $SequenceBefore
        Deadline       = $Deadline.ToString('o')
    }
    if ($env:HOTSHOT_TEST_IMAGE -ne '1') { return $null }
    $img = [pscustomobject]@{ Kind = 'stub-image' }
    $img | Add-Member -MemberType ScriptMethod -Name Save -Value {
        param($Path, $Format)
        Set-Content -Path $Path -Value 'stub-png'
        Write-StubCall 'Image.Save' @{ Path = $Path; Format = "$Format" }
    }
    return $img
}

function Resolve-HotshotDirectory {
    param([string]$Dir)
    return $Dir
}

function Get-HotshotShotPath {
    param([string]$Dir)
    Write-StubCall 'Get-HotshotShotPath' @{ Dir = $Dir }
    return (Join-Path $Dir 'hotshot-stub.png')
}

function New-HotshotClipboardDataObject {
    param([object]$Image, [string]$ShotPath)
    Write-StubCall 'New-HotshotClipboardDataObject' @{ ImageKind = "$($Image.Kind)"; ShotPath = $ShotPath }
    return [pscustomobject]@{ Marker = "dataobj:$ShotPath" }
}

function Set-HotshotClipboardDataObject {
    param([object]$DataObject)
    Write-StubCall 'Set-HotshotClipboardDataObject' @{ Marker = "$($DataObject.Marker)" }
}

function Get-TargetCli {
    param([uint32]$RootPid)
    Write-StubCall 'Get-TargetCli' @{ RootPid = $RootPid }
    return $env:HOTSHOT_TEST_CLI
}

function Get-HotshotTypedText {
    param([string]$ShotPath, [string]$Cli)
    Write-StubCall 'Get-HotshotTypedText' @{ ShotPath = $ShotPath; Cli = $Cli }
    return "[typed:${Cli}:$ShotPath] "
}

function Invoke-HotshotInjection {
    param([string]$Text, [IntPtr]$TerminalHandle, [switch]$NoType, [string]$ShotPath)
    Write-StubCall 'Invoke-HotshotInjection' @{
        Text           = $Text
        TerminalHandle = "$TerminalHandle"
        NoType         = [bool]$NoType
        ShotPath       = $ShotPath
    }
}

Export-ModuleMember -Function Wait-HotshotClipboardImage, Resolve-HotshotDirectory, Get-HotshotShotPath, `
    New-HotshotClipboardDataObject, Set-HotshotClipboardDataObject, Get-TargetCli, `
    Get-HotshotTypedText, Invoke-HotshotInjection
'@

    # Defined in the child's top scope, so the script resolves Start-Process
    # to this function instead of the cmdlet (functions shadow cmdlets).
    $script:StartProcessShim = @'
function Start-Process {
    param([Parameter(Position = 0)] [string]$FilePath,
          [Parameter(ValueFromRemainingArguments)] [object[]]$Rest)
    Add-Content -Path $env:HOTSHOT_TEST_LOG -Value (@{ fn = 'Start-Process'; FilePath = $FilePath } | ConvertTo-Json -Compress)
}
'@

    # Runs the installed copy of the script in a child pwsh. $Arguments is
    # spliced verbatim into the command line after the script path.
    function Invoke-CaptureScript {
        param([string]$Arguments = '', [switch]$WithImage, [string]$Cli = 'unknown')
        if ($WithImage) { $env:HOTSHOT_TEST_IMAGE = '1' } else { Remove-Item Env:HOTSHOT_TEST_IMAGE -ErrorAction SilentlyContinue }
        $env:HOTSHOT_TEST_CLI = $Cli
        $command = $script:StartProcessShim + "`n& `$env:HOTSHOT_TEST_SCRIPT $Arguments"
        $stdout = & pwsh -NoProfile -ExecutionPolicy Bypass -Command $command 2>$script:StderrFile
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Stdout   = @($stdout)
            Stderr   = (Get-Content -Raw -ErrorAction SilentlyContinue $script:StderrFile)
        }
    }

    function Read-StubCallLog {
        if (-not (Test-Path $env:HOTSHOT_TEST_LOG)) { return @() }
        @(Get-Content $env:HOTSHOT_TEST_LOG | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function Get-StubCall {
        param([string]$Function)
        @(Read-StubCallLog | Where-Object { $_.fn -eq $Function })
    }
}

Describe 'hotshot-capture.ps1' {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hotshot-capture-e2e-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null
        Copy-Item $script:CaptureSrc (Join-Path $script:TempRoot 'hotshot-capture.ps1')
        Set-Content -Path (Join-Path $script:TempRoot 'HotshotCapture.psm1') -Value $script:StubModule
        $env:HOTSHOT_TEST_SCRIPT = Join-Path $script:TempRoot 'hotshot-capture.ps1'
        $env:HOTSHOT_TEST_LOG = Join-Path $script:TempRoot 'calls.jsonl'
        $script:StderrFile = Join-Path $script:TempRoot 'stderr.txt'
        $script:ShotDir = Join-Path $script:TempRoot 'nested' 'shots'   # must not pre-exist
        $script:ExpectedShot = Join-Path $script:ShotDir 'hotshot-stub.png'
        $script:OrigHotshotDir = $env:HOTSHOT_DIR
        Remove-Item Env:HOTSHOT_DIR -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -ne $script:OrigHotshotDir) { $env:HOTSHOT_DIR = $script:OrigHotshotDir } else { Remove-Item Env:HOTSHOT_DIR -ErrorAction SilentlyContinue }
        Remove-Item Env:HOTSHOT_TEST_SCRIPT, Env:HOTSHOT_TEST_LOG, Env:HOTSHOT_TEST_IMAGE, Env:HOTSHOT_TEST_CLI -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:TempRoot
    }

    Context 'successful capture' {
        BeforeEach {
            $script:Before = Get-Date
            $script:Result = Invoke-CaptureScript -Arguments "-Dir `"$script:ShotDir`"" -WithImage -Cli 'claude'
        }

        It 'exits 0 and prints the saved screenshot path' {
            $script:Result.ExitCode | Should -Be 0 -Because $script:Result.Stderr
            $script:Result.Stdout[-1] | Should -Be $script:ExpectedShot
        }

        It 'opens the Snipping Tool overlay via the ms-screenclip: URI' {
            $calls = Get-StubCall 'Start-Process'
            $calls.Count | Should -Be 1
            $calls[0].FilePath | Should -Be 'ms-screenclip:'
        }

        It 'waits for the clipboard with a 60 second deadline from launch' {
            $calls = Get-StubCall 'Wait-HotshotClipboardImage'
            $calls.Count | Should -Be 1
            $deadline = [datetime]::Parse($calls[0].Deadline, $null, [Globalization.DateTimeStyles]::RoundtripKind)
            ($deadline - $script:Before).TotalSeconds | Should -BeGreaterOrEqual 55
            ($deadline - $script:Before).TotalSeconds | Should -BeLessOrEqual 90
        }

        It 'creates the -Dir folder (including parents) and saves the PNG there' {
            Test-Path -PathType Container $script:ShotDir | Should -BeTrue
            Test-Path -PathType Leaf $script:ExpectedShot | Should -BeTrue
            (Get-StubCall 'Get-HotshotShotPath')[0].Dir | Should -Be $script:ShotDir
            $save = Get-StubCall 'Image.Save'
            $save.Count | Should -Be 1
            $save[0].Path | Should -Be $script:ExpectedShot
            $save[0].Format | Should -Match 'Png'
        }

        It 'rewrites the clipboard with a data object built from the captured image and saved path' {
            $new = Get-StubCall 'New-HotshotClipboardDataObject'
            $new.Count | Should -Be 1
            $new[0].ImageKind | Should -Be 'stub-image'
            $new[0].ShotPath | Should -Be $script:ExpectedShot
            $set = Get-StubCall 'Set-HotshotClipboardDataObject'
            $set.Count | Should -Be 1
            $set[0].Marker | Should -Be "dataobj:$script:ExpectedShot"
        }

        It 'feeds the detected CLI and saved path into the typed text, then injects it' {
            (Get-StubCall 'Get-TargetCli').Count | Should -Be 1
            $typed = Get-StubCall 'Get-HotshotTypedText'
            $typed.Count | Should -Be 1
            $typed[0].Cli | Should -Be 'claude'
            $typed[0].ShotPath | Should -Be $script:ExpectedShot
            $inject = Get-StubCall 'Invoke-HotshotInjection'
            $inject.Count | Should -Be 1
            $inject[0].Text | Should -Be "[typed:claude:$script:ExpectedShot] "
            $inject[0].ShotPath | Should -Be $script:ExpectedShot
            $inject[0].NoType | Should -BeFalse
        }

        It 'runs the steps in contract order: overlay, wait, save, clipboard, detect, inject' {
            $order = @(Read-StubCallLog | ForEach-Object { $_.fn })
            $order | Should -Be @(
                'Start-Process', 'Wait-HotshotClipboardImage', 'Get-HotshotShotPath', 'Image.Save',
                'New-HotshotClipboardDataObject', 'Set-HotshotClipboardDataObject',
                'Get-TargetCli', 'Get-HotshotTypedText', 'Invoke-HotshotInjection'
            )
        }
    }

    It 'passes the plain CLI classification through unchanged' {
        $result = Invoke-CaptureScript -Arguments "-Dir `"$script:ShotDir`"" -WithImage -Cli 'plain'
        $result.ExitCode | Should -Be 0 -Because $result.Stderr
        (Get-StubCall 'Get-HotshotTypedText')[0].Cli | Should -Be 'plain'
        (Get-StubCall 'Invoke-HotshotInjection')[0].Text | Should -Be "[typed:plain:$script:ExpectedShot] "
    }

    It 'forwards -NoType to the injection step and still saves and prints the path' {
        $result = Invoke-CaptureScript -Arguments "-NoType -Dir `"$script:ShotDir`"" -WithImage
        $result.ExitCode | Should -Be 0 -Because $result.Stderr
        $result.Stdout[-1] | Should -Be $script:ExpectedShot
        Test-Path $script:ExpectedShot | Should -BeTrue
        $inject = Get-StubCall 'Invoke-HotshotInjection'
        $inject.Count | Should -Be 1
        $inject[0].NoType | Should -BeTrue
    }

    It 'defaults -Dir to HOTSHOT_DIR when the environment variable is set' {
        $envDir = Join-Path $script:TempRoot 'from-env'
        $env:HOTSHOT_DIR = $envDir
        $result = Invoke-CaptureScript -WithImage
        $result.ExitCode | Should -Be 0 -Because $result.Stderr
        $result.Stdout[-1] | Should -Be (Join-Path $envDir 'hotshot-stub.png')
        Test-Path (Join-Path $envDir 'hotshot-stub.png') | Should -BeTrue
    }

    It 'prefers an explicit -Dir over HOTSHOT_DIR' {
        $env:HOTSHOT_DIR = Join-Path $script:TempRoot 'from-env'
        $result = Invoke-CaptureScript -Arguments "-Dir `"$script:ShotDir`"" -WithImage
        $result.ExitCode | Should -Be 0 -Because $result.Stderr
        $result.Stdout[-1] | Should -Be $script:ExpectedShot
        Test-Path (Join-Path $script:TempRoot 'from-env') | Should -BeFalse
    }

    # MyPictures is unknown (empty) on non-Windows hosts, where the default is meaningless.
    It 'defaults -Dir to the MyPictures hotshot folder when HOTSHOT_DIR is unset' -Skip:(-not [Environment]::GetFolderPath('MyPictures')) {
        $picturesDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'hotshot'
        $expected = Join-Path $picturesDir 'hotshot-stub.png'
        try {
            $result = Invoke-CaptureScript -WithImage
            $result.ExitCode | Should -Be 0 -Because $result.Stderr
            $result.Stdout[-1] | Should -Be $expected
            (Get-StubCall 'Get-HotshotShotPath')[0].Dir | Should -Be $picturesDir
        } finally {
            # Only the marker file: a developer's real Pictures\hotshot stays intact.
            Remove-Item -Force -ErrorAction SilentlyContinue $expected
        }
    }

    Context 'cancelled or timed-out capture' {
        BeforeEach {
            $script:Result = Invoke-CaptureScript -Arguments "-Dir `"$script:ShotDir`""   # no image
        }

        It 'exits 1 with a hotshot-prefixed error' {
            $script:Result.ExitCode | Should -Be 1
            $script:Result.Stderr | Should -Match 'hotshot: capture cancelled or timed out'
            $script:Result.Stdout | Should -BeNullOrEmpty
        }

        It 'stops before touching the filesystem, clipboard or terminal' {
            Test-Path $script:ShotDir | Should -BeFalse
            (Read-StubCallLog | ForEach-Object { $_.fn }) | Should -Be @('Start-Process', 'Wait-HotshotClipboardImage')
        }
    }

    It 'fails before launching the overlay when HotshotCapture.psm1 is not next to the script (#119)' {
        Remove-Item (Join-Path $script:TempRoot 'HotshotCapture.psm1')
        $result = Invoke-CaptureScript -Arguments "-Dir `"$script:ShotDir`"" -WithImage
        $result.ExitCode | Should -Not -Be 0
        $result.Stderr | Should -Match 'HotshotCapture\.psm1'
        (Get-StubCall 'Start-Process').Count | Should -Be 0
        Test-Path $script:ShotDir | Should -BeFalse
    }
}
