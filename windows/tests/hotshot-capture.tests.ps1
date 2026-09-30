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
        Get-RedactedPath -Path 'C:\Shots\one.png' -Verbose $false | Should -Be '<redacted>'
    }

    It 'reveals the path when verbose diagnostics are requested' {
        Get-RedactedPath -Path 'C:\Shots\one.png' -Verbose $true | Should -Be 'C:\Shots\one.png'
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
