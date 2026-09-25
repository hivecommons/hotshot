# Contributing to hotshot

Thanks for helping improve hotshot. This repository contains the macOS menu-bar app plus Linux and Windows helper scripts, so please keep platform-specific behavior aligned with the contract documented in the README.

## Development setup

Clone the repository and work on a branch:

```sh
git clone https://github.com/hivecommons/hotshot.git
cd hotshot
git checkout -b your-branch-name
```

Requirements by platform:

- macOS: Xcode or Xcode Command Line Tools with Swift 5.9 or newer.
- Linux: Bash plus the optional runtime tools listed in `linux/README.md` for manual testing.
- Windows: PowerShell 5+ for the capture scripts; AutoHotkey v2 is optional.

## Build, test, and lint

Run the checks that apply to your change before opening a PR:

```sh
swift test
bash linux/tests/hotshot-capture.test.sh
bash linux/tests/install.test.sh
shellcheck -S warning linux/hotshot-capture.sh linux/install.sh scripts/bundle.sh
pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Force -Scope CurrentUser; Invoke-ScriptAnalyzer -Path windows -Recurse -Severity Error"
pwsh -NoProfile -Command "Install-Module Pester -Force -Scope CurrentUser; Invoke-Pester -Path windows/tests -CI"
```

Notes:

- The Linux test suites are hermetic and do not need a display server, capture tools, or a real gsettings.
- `swift test` requires macOS because the executable imports AppKit; it runs the suite in `Tests/HotshotCoreTests`.
- The Pester suite (`windows/tests/hotshot-capture.tests.ps1`) exercises the Windows capture script logic and runs on `windows-latest` in CI; it's independent of the PSScriptAnalyzer lint check above.
- If you cannot run a platform-specific check locally, say so in the PR and describe the manual validation you did run.

## Coding guidelines

- Preserve README behavior parity across macOS, Linux, and Windows when changing path injection or CLI detection.
- Keep scripts dependency-light and fail with actionable messages when optional runtime tools are missing.
- Quote paths and escape text before handing it to shells, AppleScript, PowerShell, or terminal automation.
- Prefer small, focused PRs. Include tests when changing testable script logic.

## Pull requests

Every PR should include:

1. A short description of the user-visible change.
2. The checks you ran and their results.
3. Linked issues using `Fixes #123` when the PR resolves an issue.

This repository uses DCO sign-off. Commit with `git commit -s` so each commit contains a `Signed-off-by:` line.

Maintainers may ask for `/approve` and `/lgtm` labels before merging through the repository's Prow/Tide workflow. Bot-generated PRs still need human review before merge.
