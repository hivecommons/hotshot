# Changelog

All notable changes to hotshot are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [semantic versioning](https://semver.org/) with `v`-prefixed tags.

## [Unreleased]

### Added

- Homebrew install via the `hivecommons/homebrew-hive` tap: `brew install hivecommons/hive/hotshot`; the README Install section now leads with it.

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
