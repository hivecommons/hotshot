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
}

Describe 'ConvertTo-SendKeysEscaped' {
    It 'escapes SendKeys metacharacters' {
        ConvertTo-SendKeysEscaped -Text '+^%~(){}[]abc' | Should -Be '{+}{^}{%}{~}{(}{)}{{}{}}{[}{]}abc'
    }

    It 'leaves regular path characters untouched' {
        ConvertTo-SendKeysEscaped -Text 'C:\Shots\one.png ' | Should -Be 'C:\Shots\one.png '
    }
}
