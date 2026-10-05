BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'HotshotCapture.psm1') -Force
}

Describe 'Get-TargetCli' {
    BeforeEach {
        Mock Get-CimInstance -ModuleName HotshotCapture {
            @(
                [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; Name = 'WindowsTerminal.exe'; CommandLine = 'wt.exe' }
                [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; Name = $script:ChildName; CommandLine = $script:ChildCommandLine }
                [pscustomobject]@{ ProcessId = 300; ParentProcessId = 200; Name = $script:GrandchildName; CommandLine = $script:GrandchildCommandLine }
            )
        }
    }

    It 'returns unknown without a root process id' {
        Get-TargetCli 0 | Should -Be 'unknown'
    }

    It 'detects claude by process name' {
        $script:ChildName = 'claude.exe'
        $script:ChildCommandLine = 'claude'
        $script:GrandchildName = 'pwsh.exe'
        $script:GrandchildCommandLine = 'pwsh'

        Get-TargetCli 100 | Should -Be 'claude'
    }

    It 'detects claude-code from a descendant command line' {
        $script:ChildName = 'node.exe'
        $script:ChildCommandLine = 'node C:\Tools\claude-code.cmd'
        $script:GrandchildName = 'pwsh.exe'
        $script:GrandchildCommandLine = 'pwsh'

        Get-TargetCli 100 | Should -Be 'claude'
    }

    It 'detects plain-path CLIs from descendants' {
        $script:ChildName = 'pwsh.exe'
        $script:ChildCommandLine = 'pwsh'
        $script:GrandchildName = 'node.exe'
        $script:GrandchildCommandLine = 'node C:\Tools\copilot.cmd'

        Get-TargetCli 100 | Should -Be 'plain'
    }

    It 'prefers claude when both claude and plain CLIs are present' {
        $script:ChildName = 'aider.exe'
        $script:ChildCommandLine = 'aider'
        $script:GrandchildName = 'claude.exe'
        $script:GrandchildCommandLine = 'claude'

        Get-TargetCli 100 | Should -Be 'claude'
    }

    It 'returns unknown when no known CLI is found' {
        $script:ChildName = 'pwsh.exe'
        $script:ChildCommandLine = 'pwsh'
        $script:GrandchildName = 'vim.exe'
        $script:GrandchildCommandLine = 'vim README.md'

        Get-TargetCli 100 | Should -Be 'unknown'
    }

    It 'rejects substring lookalikes (macOS whole-token parity)' {
        # Parity with HotshotCore.classifyCommands: only an exact CLI name may
        # pick an injection format — "claudette"/"claude2" must not classify.
        $script:ChildName = 'claudette.exe'
        $script:ChildCommandLine = 'C:\Tools\claudette.exe'
        $script:GrandchildName = 'node.exe'
        $script:GrandchildCommandLine = 'node C:\Tools\claude2.cmd'

        Get-TargetCli 100 | Should -Be 'unknown'
    }

    It 'does not classify a plain CLI from a filename argument lookalike' {
        $script:ChildName = 'vim.exe'
        $script:ChildCommandLine = 'vim copilot-notes.md'
        $script:GrandchildName = 'pwsh.exe'
        $script:GrandchildCommandLine = 'pwsh'

        Get-TargetCli 100 | Should -Be 'unknown'
    }

    It 'detects claude from a quoted command line path' {
        $script:ChildName = 'node.exe'
        $script:ChildCommandLine = '"C:\Program Files\claude tools\claude.cmd" --resume'
        $script:GrandchildName = 'pwsh.exe'
        $script:GrandchildCommandLine = 'pwsh'

        Get-TargetCli 100 | Should -Be 'claude'
    }

    It 'returns unknown when Get-CimInstance yields no processes' {
        Mock Get-CimInstance -ModuleName HotshotCapture { @() }

        Get-TargetCli 100 | Should -Be 'unknown'
    }

    It 'tolerates processes with a null Name and CommandLine' {
        # Win32_Process reports CommandLine (and sometimes Name) as $null for
        # protected or elevated processes the caller cannot inspect. The walk
        # must not throw on those rows and must still classify descendants.
        Mock Get-CimInstance -ModuleName HotshotCapture {
            @(
                [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; Name = 'WindowsTerminal.exe'; CommandLine = $null }
                [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; Name = $null; CommandLine = $null }
                [pscustomobject]@{ ProcessId = 300; ParentProcessId = 200; Name = 'node.exe'; CommandLine = 'node C:\Tools\aider.cmd' }
            )
        }

        Get-TargetCli 100 | Should -Be 'plain'
    }

    It 'classifies claude by Name when CommandLine is null' {
        Mock Get-CimInstance -ModuleName HotshotCapture {
            @(
                [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; Name = 'WindowsTerminal.exe'; CommandLine = 'wt.exe' }
                [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; Name = 'claude.exe'; CommandLine = $null }
            )
        }

        Get-TargetCli 100 | Should -Be 'claude'
    }

    It 'returns unknown when every walked process has null Name and CommandLine' {
        Mock Get-CimInstance -ModuleName HotshotCapture {
            @(
                [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; Name = $null; CommandLine = $null }
                [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; Name = $null; CommandLine = $null }
            )
        }

        Get-TargetCli 100 | Should -Be 'unknown'
    }

    It 'terminates on parent-pid cycles instead of looping forever' {
        # A stale ParentProcessId can point back into the walked tree (PIDs
        # are recycled on Windows); the seen-set must break the loop.
        Mock Get-CimInstance -ModuleName HotshotCapture {
            @(
                [pscustomobject]@{ ProcessId = 100; ParentProcessId = 200; Name = 'WindowsTerminal.exe'; CommandLine = 'wt.exe' }
                [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; Name = 'pwsh.exe'; CommandLine = 'pwsh' }
            )
        }

        Get-TargetCli 100 | Should -Be 'unknown'
    }
}

Describe 'Get-HotshotTypedText' {
    It 'brackets paths for claude and unknown CLI targets' {
        Get-HotshotTypedText -ShotPath 'C:\Shots\one.png' -Cli claude | Should -Be '[C:\Shots\one.png] '
        Get-HotshotTypedText -ShotPath 'C:\Shots\one.png' -Cli unknown | Should -Be '[C:\Shots\one.png] '
    }

    It 'quotes plain CLI paths only when whitespace is present' {
        Get-HotshotTypedText -ShotPath 'C:\Shots\one.png' -Cli plain | Should -Be 'C:\Shots\one.png '
        Get-HotshotTypedText -ShotPath 'C:\My Shots\one.png' -Cli plain | Should -Be '"C:\My Shots\one.png" '
    }

    It 'refuses paths containing control characters (macOS parity)' {
        foreach ($cli in @('claude', 'plain', 'unknown')) {
            Get-HotshotTypedText -ShotPath "C:\Shots\evil`r`n\one.png" -Cli $cli | Should -Be ''
            Get-HotshotTypedText -ShotPath "C:\Shots\evil`t\one.png" -Cli $cli | Should -Be ''
            Get-HotshotTypedText -ShotPath ("C:\Shots\evil" + [char]0x7F + "\one.png") -Cli $cli | Should -Be ''
            Get-HotshotTypedText -ShotPath ("C:\Shots\evil" + [char]0x2028 + "\one.png") -Cli $cli | Should -Be ''
            Get-HotshotTypedText -ShotPath ("C:\Shots\evil" + [char]0x2029 + "\one.png") -Cli $cli | Should -Be ''
        }
    }
}

Describe 'ConvertTo-SendKeysEscaped' {
    It 'escapes SendKeys metacharacters' {
        ConvertTo-SendKeysEscaped -Text '+^%~(){}[]abc' | Should -Be '{+}{^}{%}{~}{(}{)}{{}{}}{[}{]}abc'
    }

    It 'leaves regular path characters untouched' {
        ConvertTo-SendKeysEscaped -Text 'C:\Shots\one.png ' | Should -Be 'C:\Shots\one.png '
    }
}

Describe 'Get-HotshotVerboseLogging' {
    AfterEach { Remove-Item Env:\HOTSHOT_VERBOSE_LOGGING -ErrorAction SilentlyContinue }

    It 'is disabled when the env var is unset' {
        Remove-Item Env:\HOTSHOT_VERBOSE_LOGGING -ErrorAction SilentlyContinue
        Get-HotshotVerboseLogging | Should -Be $false
    }

    It 'is enabled only by an exact "1"' {
        $env:HOTSHOT_VERBOSE_LOGGING = '1'
        Get-HotshotVerboseLogging | Should -Be $true
    }

    It 'rejects other truthy-looking values' {
        $env:HOTSHOT_VERBOSE_LOGGING = 'true'
        Get-HotshotVerboseLogging | Should -Be $false
    }
}

Describe 'Get-RedactedPath' {
    It 'redacts the path by default (issue #77: no paths in normal diagnostics)' {
        Get-RedactedPath -Path 'C:\Shots\one.png' -VerboseLogging $false | Should -Be '<redacted>'
    }

    It 'reveals the path when verbose diagnostics are requested' {
        Get-RedactedPath -Path 'C:\Shots\one.png' -VerboseLogging $true | Should -Be 'C:\Shots\one.png'
    }
}

Describe 'Format-HotshotDiagnostic' {
    It 'formats a stable event name and severity without detail' {
        Format-HotshotDiagnostic -Severity INFO -Event 'watcher.started' | Should -Be 'hotshot [INFO] watcher.started'
    }

    It 'appends detail when present' {
        Format-HotshotDiagnostic -Severity WARN -Event 'injection.control_chars_refused' -Detail 'path=<redacted>' |
            Should -Be 'hotshot [WARN] injection.control_chars_refused: path=<redacted>'
    }

    It 'omits the colon separator when detail is empty' {
        Format-HotshotDiagnostic -Severity ERROR -Event 'clipboard.rewrite_failed' | Should -Be 'hotshot [ERROR] clipboard.rewrite_failed'
    }
}

Describe 'Wait-HotshotClipboardImage' {
    BeforeEach {
        $script:Seq = [System.Collections.Generic.Queue[uint32]]::new()
        $script:Clock = [datetime]'2026-01-01T00:00:00'
        $script:Deadline = $script:Clock.AddSeconds(60)
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Now = { $script:Clock }
        $script:Sleep = { $script:Clock = $script:Clock.AddMilliseconds(250); $script:Calls.Add('sleep') }
        $script:GetSequence = { if ($script:Seq.Count -gt 0) { $script:Seq.Dequeue() } else { [uint32]7 } }
    }

    It 'returns the image on the first sequence change that carries one' {
        foreach ($n in 7, 7, 8) { $script:Seq.Enqueue($n) }
        $result = Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline $script:Deadline `
            -GetSequence $script:GetSequence -Now $script:Now -Sleep $script:Sleep `
            -ContainsImage { $true } -GetImage { 'IMG' }

        $result | Should -Be 'IMG'
        $script:Calls.Count | Should -Be 3
    }

    It 'ignores a sequence change without an image and keeps waiting' {
        foreach ($n in 8, 9) { $script:Seq.Enqueue($n) }
        $script:HasImage = [System.Collections.Generic.Queue[bool]]::new()
        foreach ($b in $false, $true) { $script:HasImage.Enqueue($b) }
        $result = Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline $script:Deadline `
            -GetSequence $script:GetSequence -Now $script:Now -Sleep $script:Sleep `
            -ContainsImage { $script:HasImage.Dequeue() } -GetImage { 'IMG' }

        $result | Should -Be 'IMG'
        $script:Calls.Count | Should -Be 2
    }

    It 'keeps waiting when the clipboard reports an image but GetImage returns nothing' {
        foreach ($n in 8, 9) { $script:Seq.Enqueue($n) }
        $script:Images = [System.Collections.Generic.Queue[object]]::new()
        $script:Images.Enqueue($null); $script:Images.Enqueue('IMG')
        $result = Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline $script:Deadline `
            -GetSequence $script:GetSequence -Now $script:Now -Sleep $script:Sleep `
            -ContainsImage { $true } -GetImage { $script:Images.Dequeue() }

        $result | Should -Be 'IMG'
    }

    It 'returns $null at the deadline when the capture is cancelled (sequence never changes)' {
        $result = Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline $script:Deadline `
            -GetSequence $script:GetSequence -Now $script:Now -Sleep $script:Sleep `
            -ContainsImage { throw 'must not be called' } -GetImage { throw 'must not be called' }

        $result | Should -BeNullOrEmpty
        $script:Calls.Count | Should -Be 240
    }

    It 'returns $null at the deadline when no image ever appears' {
        $result = Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline $script:Deadline `
            -GetSequence { [uint32]8 } -Now $script:Now -Sleep $script:Sleep `
            -ContainsImage { $false } -GetImage { throw 'must not be called' }

        $result | Should -BeNullOrEmpty
    }

    It 'returns $null immediately when the deadline has already passed' {
        $result = Wait-HotshotClipboardImage -SequenceBefore 7 -Deadline $script:Clock.AddSeconds(-1) `
            -GetSequence $script:GetSequence -Now $script:Now -Sleep $script:Sleep `
            -ContainsImage { $true } -GetImage { 'IMG' }

        $result | Should -BeNullOrEmpty
        $script:Calls.Count | Should -Be 0
    }
}

Describe 'Get-HotshotShotPath' {
    It 'names the PNG hotshot-yyyyMMdd-HHmmss.png inside the target directory' {
        $path = Get-HotshotShotPath -Dir (Join-Path 'C:' 'Shots') -Timestamp ([datetime]'2026-03-04T05:06:07')
        Split-Path $path -Leaf | Should -Be 'hotshot-20260304-050607.png'
        Split-Path $path -Parent | Should -Be (Join-Path 'C:' 'Shots')
    }
}

Describe 'New-HotshotClipboardDataObject' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }

    It 'carries the image, the plain-text path and a file drop list' {
        $bmp = [System.Drawing.Bitmap]::new(2, 2)
        try {
            $obj = New-HotshotClipboardDataObject -Image $bmp -ShotPath 'C:\Shots\hotshot-1.png'

            $obj | Should -BeOfType System.Windows.Forms.DataObject
            $obj.ContainsImage() | Should -BeTrue
            $obj.GetText() | Should -Be 'C:\Shots\hotshot-1.png'
            $drop = $obj.GetFileDropList()
            $drop.Count | Should -Be 1
            $drop[0] | Should -Be 'C:\Shots\hotshot-1.png'
        } finally {
            $bmp.Dispose()
        }
    }
}

Describe 'Set-HotshotClipboardDataObject' {
    It 'hands the data object to the clipboard setter' {
        $script:Received = $null
        Set-HotshotClipboardDataObject -DataObject 'DATA' -SetDataObject { param($o) $script:Received = $o } -WarningVariable w -WarningAction SilentlyContinue

        $script:Received | Should -Be 'DATA'
        $w | Should -BeNullOrEmpty
    }

    It 'warns instead of failing when the clipboard cannot be rewritten' {
        { Set-HotshotClipboardDataObject -DataObject 'DATA' -SetDataObject { throw 'clipboard busy' } -WarningVariable w -WarningAction SilentlyContinue
            $script:Warnings = $w } | Should -Not -Throw

        $script:Warnings.Count | Should -Be 1
        "$($script:Warnings[0])" | Should -Be 'hotshot: could not rewrite the clipboard: clipboard busy'
    }
}

Describe 'Invoke-HotshotInjection' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Fakes = @{
            SetForeground = { param($h) $script:Calls.Add("foreground:$h") }
            SendKeys      = { param($k) $script:Calls.Add("send:$k") }
            Sleep         = { $script:Calls.Add('sleep') }
        }
        $script:Hwnd = [IntPtr]42
        $env:HOTSHOT_VERBOSE_LOGGING = $null
    }

    AfterEach {
        $env:HOTSHOT_VERBOSE_LOGGING = $null
    }

    It 'refocuses the terminal, then types the SendKeys-escaped text' {
        $fakes = $script:Fakes
        Invoke-HotshotInjection -Text '[C:\Shots\a+b.png] ' -TerminalHandle $script:Hwnd -ShotPath 'C:\Shots\a+b.png' `
            @fakes -WarningVariable w -WarningAction SilentlyContinue

        $script:Calls | Should -Be @('foreground:42', 'sleep', 'send:{[}C:\Shots\a{+}b.png{]} ')
        $w | Should -BeNullOrEmpty
    }

    It 'sends nothing with -NoType' {
        $fakes = $script:Fakes
        Invoke-HotshotInjection -Text '[C:\Shots\a.png] ' -TerminalHandle $script:Hwnd -NoType -ShotPath 'C:\Shots\a.png' `
            @fakes -WarningVariable w -WarningAction SilentlyContinue

        $script:Calls.Count | Should -Be 0
        $w | Should -BeNullOrEmpty
    }

    It 'warns injection.control_chars_refused with a redacted path when the text is empty' {
        $fakes = $script:Fakes
        Invoke-HotshotInjection -Text '' -TerminalHandle $script:Hwnd -ShotPath "C:\Shots\a`n.png" `
            @fakes -WarningVariable w -WarningAction SilentlyContinue

        $script:Calls.Count | Should -Be 0
        "$w" | Should -Be 'hotshot [WARN] injection.control_chars_refused: path=<redacted>'
    }

    It 'reveals the path in the control_chars_refused warning when verbose logging is on' {
        $fakes = $script:Fakes
        $env:HOTSHOT_VERBOSE_LOGGING = '1'
        Invoke-HotshotInjection -Text '' -TerminalHandle $script:Hwnd -ShotPath 'C:\Shots\a.png' `
            @fakes -WarningVariable w -WarningAction SilentlyContinue

        "$w" | Should -Be 'hotshot [WARN] injection.control_chars_refused: path=C:\Shots\a.png'
    }

    It 'warns injection.no_foreground_terminal when no terminal window was focused' {
        $fakes = $script:Fakes
        Invoke-HotshotInjection -Text '[C:\Shots\a.png] ' -TerminalHandle ([IntPtr]::Zero) -ShotPath 'C:\Shots\a.png' `
            @fakes -WarningVariable w -WarningAction SilentlyContinue

        $script:Calls.Count | Should -Be 0
        "$w" | Should -Be 'hotshot [WARN] injection.no_foreground_terminal'
    }

    It 'warns injection.sendkeys_failed instead of failing when SendWait throws' {
        $fakes = $script:Fakes.Clone()
        $fakes.SendKeys = { param($k) throw 'access denied' }
        { Invoke-HotshotInjection -Text '[C:\Shots\a.png] ' -TerminalHandle $script:Hwnd -ShotPath 'C:\Shots\a.png' `
                @fakes -WarningVariable w -WarningAction SilentlyContinue
            $script:Warnings = $w } | Should -Not -Throw

        $script:Calls | Should -Be @('foreground:42', 'sleep')
        "$($script:Warnings)" | Should -Be 'hotshot [WARN] injection.sendkeys_failed: access denied'
    }
}
