# Integration tests for install.ps1. Every install run is sandboxed by
# pointing LOCALAPPDATA at a per-test temp directory (child processes inherit
# $env:), so the runner's real %LOCALAPPDATA%\Hotshot is never touched. The
# Start Menu shortcut lands in the runner's real Start Menu (its path comes
# from [Environment]::GetFolderPath and cannot be redirected), so each test
# removes it when done.
#
# The installer calls `exit`, so it must always run in a child pwsh process —
# never dot-sourced or &-invoked — or a failure path would kill the test host.

BeforeAll {
    $script:InstallerSrc = Join-Path $PSScriptRoot '..' 'install.ps1'
    $script:CaptureSrc = Join-Path $PSScriptRoot '..' 'hotshot-capture.ps1'
    $script:AhkSrc = Join-Path $PSScriptRoot '..' 'hotshot.ahk'
    $script:StartMenu = [Environment]::GetFolderPath('StartMenu')
    $script:ShortcutPath = Join-Path $script:StartMenu 'Programs\hotshot.lnk'
    $script:OrigLocalAppData = $env:LOCALAPPDATA

    function Invoke-Installer {
        param([string[]]$Arguments = @(), [string]$Installer = $script:InstallerSrc)
        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Installer @Arguments *>&1 |
            Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    function Read-Shortcut {
        param([string]$Path)
        $shell = New-Object -ComObject WScript.Shell
        $shell.CreateShortcut($Path)
    }
}

Describe 'install.ps1' {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hotshot-install-tests-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null
        $env:LOCALAPPDATA = $script:TempRoot
        $script:InstallDir = Join-Path $script:TempRoot 'Hotshot'
        Remove-Item -Force -ErrorAction SilentlyContinue $script:ShortcutPath
    }

    AfterEach {
        Remove-Item -Force -ErrorAction SilentlyContinue $script:ShortcutPath
        $env:LOCALAPPDATA = $script:OrigLocalAppData
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:TempRoot
    }

    It 'copies hotshot-capture.ps1 and hotshot.ahk into LOCALAPPDATA\Hotshot' {
        $result = Invoke-Installer

        $result.ExitCode | Should -Be 0
        Join-Path $script:InstallDir 'hotshot-capture.ps1' | Should -Exist
        Join-Path $script:InstallDir 'hotshot.ahk' | Should -Exist
        (Get-Content (Join-Path $script:InstallDir 'hotshot-capture.ps1') -Raw) |
            Should -Be (Get-Content $script:CaptureSrc -Raw)
    }

    It 'creates a Start Menu shortcut targeting powershell with the installed script' {
        $result = Invoke-Installer

        $result.ExitCode | Should -Be 0
        $script:ShortcutPath | Should -Exist
        $sc = Read-Shortcut $script:ShortcutPath
        $sc.TargetPath | Should -Match 'powershell\.exe$'
        $sc.Arguments | Should -Match '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File'
        # The shortcut must launch the installed copy, quoted (LOCALAPPDATA can
        # contain spaces), not the checkout copy.
        $sc.Arguments | Should -BeLike ('*"' + (Join-Path $script:InstallDir 'hotshot-capture.ps1') + '"*')
        $sc.WorkingDirectory | Should -Be $script:InstallDir
        $sc.WindowStyle | Should -Be 7
    }

    It 'binds the default Ctrl+Alt+H hotkey on the shortcut' {
        Invoke-Installer | Out-Null

        $sc = Read-Shortcut $script:ShortcutPath
        $sc.Hotkey | Should -Match 'Ctrl\+'
        $sc.Hotkey | Should -Match 'Alt\+'
        $sc.Hotkey | Should -Match '\+H$'
    }

    It 'honors a custom -Hotkey' {
        $result = Invoke-Installer -Arguments @('-Hotkey', 'Ctrl+Alt+P')

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape('Ctrl+Alt+P'))
        (Read-Shortcut $script:ShortcutPath).Hotkey | Should -Match '\+P$'
    }

    It 'reports where it installed' {
        $result = Invoke-Installer

        $result.Output | Should -Match ([regex]::Escape($script:InstallDir))
        $result.Output | Should -Match ([regex]::Escape($script:ShortcutPath))
    }

    It '-Uninstall removes the shortcut and the install directory' {
        Invoke-Installer | Out-Null
        $script:ShortcutPath | Should -Exist

        $result = Invoke-Installer -Arguments @('-Uninstall')

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'hotshot uninstalled\.'
        $script:ShortcutPath | Should -Not -Exist
        $script:InstallDir | Should -Not -Exist
    }

    It '-Uninstall succeeds when nothing is installed' {
        $result = Invoke-Installer -Arguments @('-Uninstall')

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'hotshot uninstalled\.'
    }

    It 'fails without touching the Start Menu when hotshot-capture.ps1 is missing' {
        $orphanDir = Join-Path $script:TempRoot 'orphan'
        New-Item -ItemType Directory -Force -Path $orphanDir | Out-Null
        Copy-Item $script:InstallerSrc (Join-Path $orphanDir 'install.ps1')

        $result = Invoke-Installer -Installer (Join-Path $orphanDir 'install.ps1')

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'hotshot-capture\.ps1 not found'
        $script:ShortcutPath | Should -Not -Exist
        $script:InstallDir | Should -Not -Exist
    }

    It 'installs without hotshot.ahk when it is absent next to the installer' {
        $bareDir = Join-Path $script:TempRoot 'bare'
        New-Item -ItemType Directory -Force -Path $bareDir | Out-Null
        Copy-Item $script:InstallerSrc (Join-Path $bareDir 'install.ps1')
        Copy-Item $script:CaptureSrc (Join-Path $bareDir 'hotshot-capture.ps1')

        $result = Invoke-Installer -Installer (Join-Path $bareDir 'install.ps1')

        $result.ExitCode | Should -Be 0
        Join-Path $script:InstallDir 'hotshot-capture.ps1' | Should -Exist
        Join-Path $script:InstallDir 'hotshot.ahk' | Should -Not -Exist
        $script:ShortcutPath | Should -Exist
    }
}
