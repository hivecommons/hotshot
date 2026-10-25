# Changelog

All notable changes to hotshot are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [semantic versioning](https://semver.org/) with `v`-prefixed tags.

## [Unreleased]

### Added

- Menu action "Use macOS default folder" (shown while a custom screenshot folder is set) reverts the override, and the `Save to:` line now says whether the folder is the macOS default or custom (#297).
- Homebrew install via the `hivecommons/homebrew-hive` tap: `brew install hivecommons/hive/hotshot`; the README Install section now leads with it.

### Fixed

- macOS: hotshot now recognises its own enriched clipboard text when the screenshot folder path contains a backslash, instead of saving a duplicate PNG each time (#301).
- Linux and Windows: when a terminal process tree runs both claude and a plain-path CLI (multi-tab terminal servers), classification now returns the escaped bare path instead of the bracketed claude format (#294).
- Windows: `Get-TargetCli` no longer classifies `CLAUDE.md` or a `claude\` path segment in a child command line as the claude CLI (#290).
- Linux and Windows: target classification now matches CLI names per command-line argument, so a `claude <x>` path component no longer selects the claude format (#292).
- Watch mode now follows an external change of the macOS screenshot location instead of staying on the old folder, and reading that location no longer forks `defaults` on every lookup.
- A focus-lost or refused-filename injection now posts only its own notification instead of also telling you to re-allow Automation.

## [0.1.0] - 2026-10-23

First tagged release. Full auto-generated notes are on the [GitHub Release](https://github.com/hivecommons/hotshot/releases/tag/v0.1.0).

### Added

- macOS menu-bar app, Linux shell script (X11 and Wayland) and Windows PowerShell helper (with optional AutoHotkey v2) that turn a screenshot into a path in your AI terminal.
- CLI-aware text injection for Claude Code, GitHub Copilot CLI, aider and opencode, with safe fallback for unknown targets.
- Clipboard enrichment with image data, file URLs and shell-escaped text paths.
- `scripts/bundle.sh` to build and install a macOS app bundle, and `--uninstall` support in the Linux and Windows installers.
- Hermetic Linux and Windows test suites and extracted `HotshotCore` helpers for shared macOS decision logic.
- Runbooks for injection failures, release rollback and postmortems.

[Unreleased]: https://github.com/hivecommons/hotshot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hivecommons/hotshot/releases/tag/v0.1.0
