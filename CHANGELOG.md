# Changelog

All notable changes to hotshot are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [semantic versioning](https://semver.org/) with `v`-prefixed tags.

## [Unreleased]

### Changed

- CI: the Swift, Pester and shell coverage gates now also fail when a floor lags the measured figure by more than 5 points, telling the author to raise the floor in the same PR; the Pester floor for `windows/HotshotCapture.psm1` rises from 88% to 90% (#348).

### Fixed

- Linux: the screenshot name keeps its milliseconds on busybox `date` (Alpine/postmarketOS), where `%3N` is unsupported and used to produce `hotshot-YYYYMMDD-HHMMSS-.png` (#368).
- Guard: `scripts/runbook-events.sh` now keeps its reverse-DNS exclusion list in a documented `REVERSE_DNS_TLDS` variable (adding `co`, `uk`, `de`) and fails if an excluded prefix collides with an emitted event category, so the list can neither misclassify identifiers nor hide a real event (#345).
- Runbooks: `runbooks/injection-failure.md` now documents the `injection.iterm2` and `injection.iterm2.script` diagnostic events emitted by iTerm2 injection on macOS, so operators triaging iTerm2 captures have event entries in the runbook.
- Guard: `scripts/runbook-events.sh` now recognises event names with digits (e.g. `iterm2`) and more than two segments (e.g. `injection.iterm2.script`) so the runbook/source guard can validate them, matching the documented events in the runbooks.
- Runbook: the Linux `cli.detection_unavailable` warning is now listed in `runbooks/injection-failure.md`, so operators who see it have a triage entry.
- Linux: the screenshot filename is now reserved atomically before capture, so two captures in the same millisecond can no longer overwrite each other; the empty reservation is removed if the capture fails or is cancelled (#329).
- Windows: the screenshot filename is now reserved atomically (`CreateNew`) before the PNG is saved, so two captures in the same millisecond can no longer overwrite each other; the empty reservation is removed if the save fails (#333).
- Windows: when the screenshot file cannot be reserved for a reason other than a name collision (e.g. a read-only folder), the capture script now exits with a `hotshot: cannot reserve a screenshot file in <redacted> (<error type>)` message, matching the Linux port, instead of an unwrapped PowerShell exception that printed the full folder path (#335).
- Windows: when the screenshot directory cannot be created (e.g. a parent path that is a file), the capture script now exits with `hotshot: cannot create screenshot directory <redacted> (<error type>)`, matching the Linux port, instead of a PowerShell error that printed the full folder path (#359).
- Windows: when the PNG cannot be saved after the filename was reserved (e.g. the folder was removed in between), the capture script now exits with `hotshot: could not save screenshot in <redacted> (<error type>)`, like the reservation error, instead of echoing the .NET message, which can name the folder and file; `HOTSHOT_VERBOSE_LOGGING=1` keeps the full message.
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
