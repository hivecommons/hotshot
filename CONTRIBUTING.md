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
swift test --enable-code-coverage
bash scripts/shell-coverage.sh
shellcheck -S warning linux/hotshot-capture.sh linux/install.sh linux/tests/hotshot-capture.test.sh linux/tests/install.test.sh scripts/bundle.sh scripts/tests/bundle.test.sh scripts/shell-coverage.sh
pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Force -Scope CurrentUser; Invoke-ScriptAnalyzer -Path windows -Recurse -Severity Error"
pwsh -NoProfile -Command "Install-Module Pester -Force -Scope CurrentUser; Invoke-Pester -Path windows/tests -CI"
```

CI (`.github/workflows/ci.yml`) runs the same checks and additionally enforces coverage floors, so a change that passes its tests can still fail CI if it adds untested lines:

- Swift: `HotshotCore` and `HotshotApp` must each stay at or above 95% line coverage (the `floors` dict in the *Swift build* job). Read the per-file figures from `llvm-cov report` as the CI job does, or from the `.profdata` that `swift test --enable-code-coverage` writes under `swift build --show-bin-path`/codecov.
- Shell: `scripts/shell-coverage.sh` runs `linux/tests/hotshot-capture.test.sh`, `linux/tests/install.test.sh` and `scripts/tests/bundle.test.sh` under xtrace and requires 95% line coverage of `linux/hotshot-capture.sh`, `linux/install.sh` and `scripts/bundle.sh`. Each suite can still be run on its own with `bash <suite>`; override a floor while iterating with `HOTSHOT_FLOOR_CAPTURE`, `HOTSHOT_FLOOR_INSTALL` or `HOTSHOT_FLOOR_BUNDLE`.
- PowerShell: the Pester job measures `windows/HotshotCapture.psm1` with an 88% coverage target (`CodeCoverage.CoveragePercentTarget` in the *Pester* job). `install.ps1` and `hotshot-capture.ps1` run in a child `pwsh`, so their suites exercise them without contributing to that figure.

The floors sit a few points under what `main` measures; when your PR lifts coverage, raise them in the same PR.

Notes:

- The Linux test suites are hermetic and do not need a display server, capture tools, or a real gsettings.
- `swift test` requires macOS because the app targets import AppKit; it runs the suites in `Tests/HotshotCoreTests` (pure decisions) and `Tests/HotshotAppTests` (the pasteboard/watcher/injector shells, the injection coordinator, the menu model and its `NSMenu` builder, and the target tracker in `Sources/HotshotApp`).
- The Pester suite (`windows/tests/hotshot-capture.tests.ps1`) exercises the Windows capture script logic — including the capture orchestration (clipboard wait loop, multi-format clipboard, typed-injection fallbacks) via injectable scriptblock collaborators, so no Snipping Tool, clipboard, or foreground window is needed — and runs on `windows-latest` in CI; it's independent of the PSScriptAnalyzer lint check above. `windows/tests/hotshot-capture.e2e.tests.ps1` runs the real `hotshot-capture.ps1` in a child `pwsh` against a recording stub of `HotshotCapture.psm1` to check the script's own wiring (parameter defaults, step order, failure exits); like `install.tests.ps1` it needs Windows because the script loads WinForms and `System.Drawing`.
- If you cannot run a platform-specific check locally, say so in the PR and describe the manual validation you did run.

## Runbooks

The [`runbooks/`](runbooks/) directory holds [injection-failure.md](runbooks/injection-failure.md) (triage for "nothing lands in the terminal"), [release-rollback.md](runbooks/release-rollback.md), and [postmortem-template.md](runbooks/postmortem-template.md) for regressions that reached users.

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
