# Changelog

All notable changes to hotshot are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [semantic versioning](https://semver.org/) with `v`-prefixed tags.

## [Unreleased]

### Fixed

- macOS: a screenshot watch whose first `start()` could not open the folder (not yet creatable, privacy permission not yet granted, volume not mounted) is now retried by the 30 s reconcile timer instead of staying dead until auto-watch is toggled or the app relaunched; the same retry re-arms a watch lost to a failed folder rebind (#327).

## [0.2.0] - 2026-10-29

### Added

- macOS and Linux: Gemini CLI is recognised and gets its `@path` form (`@` plus the backslash-escaped path) instead of the bracketed fallback (#307).
- Windows: Gemini CLI is recognised and gets `@"path"` (`@` plus the always double-quoted raw path), which Gemini CLI accepts on win32 without backslash unescaping (follow-up to #307).
- Menu action "Use macOS default folder" (shown while a custom screenshot folder is set) reverts the override, and the `Save to:` line now says whether the folder is the macOS default or custom (#297).
- Homebrew install via the `hivecommons/homebrew-hive` tap: `brew install hivecommons/hive/hotshot`; the README Install section now leads with it.

### Fixed

- Linux: CLI detection falls back to `pgrep -P` or `/proc/*/stat` on kernels without `CONFIG_PROC_CHILDREN`, and logs `WARN cli.detection_unavailable` when no process-tree source is usable.
- macOS: hotshot now recognises its own enriched clipboard text when the screenshot folder path contains a backslash, instead of saving a duplicate PNG each time (#301).
- Linux and Windows: when a terminal process tree runs both claude and a plain-path CLI (multi-tab terminal servers), classification now returns the escaped bare path instead of the bracketed claude format (#294).
- Windows: `Get-TargetCli` no longer classifies `CLAUDE.md` or a `claude\` path segment in a child command line as the claude CLI (#290).
- Linux and Windows: target classification now matches CLI names per command-line argument, so a `claude <x>` path component no longer selects the claude format (#292).
- Watch mode now follows an external change of the macOS screenshot location instead of staying on the old folder, and reading that location no longer forks `defaults` on every lookup.
- A focus-lost or refused-filename injection now posts only its own notification instead of also telling you to re-allow Automation.
- Linux: the CopyQ clipboard entry now also carries a `text/uri-list` file URI alongside the PNG and the plain path (#309).
- macOS: `scripts/bundle.sh` now derives `CFBundleShortVersionString` from the git tag (`v0.2.0` gives `0.2.0`) instead of a hard-coded `1.0.0`, and sets `CFBundleVersion` to the full `git describe` string (#300).

## [0.1.0] - 2026-10-23

First tagged release. Full auto-generated notes are on the [GitHub Release](https://github.com/hivecommons/hotshot/releases/tag/v0.1.0).

### Added

- macOS menu-bar app, Linux shell script (X11 and Wayland) and Windows PowerShell helper (with optional AutoHotkey v2) that turn a screenshot into a path in your AI terminal.
- CLI-aware text injection for Claude Code, GitHub Copilot CLI, aider and opencode, with safe fallback for unknown targets.
- Clipboard enrichment with image data, file URLs and shell-escaped text paths.
- `scripts/bundle.sh` to build and install a macOS app bundle, and `--uninstall` support in the Linux and Windows installers.
- Hermetic Linux and Windows test suites and extracted `HotshotCore` helpers for shared macOS decision logic.
- Runbooks for injection failures, release rollback and postmortems.

[Unreleased]: https://github.com/hivecommons/hotshot/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/hivecommons/hotshot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hivecommons/hotshot/releases/tag/v0.1.0
