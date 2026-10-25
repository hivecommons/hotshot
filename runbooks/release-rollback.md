# Runbook: rolling back to a known-good hotshot build

hotshot is built from source on each machine (`swift build -c release`, or `scripts/bundle.sh` for an app bundle). Releases are tagged `v`-prefixed semver versions (starting at v0.1.0) on GitHub, but there is no auto-updater and no published binary, so a bad change only reaches a machine when its user pulls and rebuilds. Rolling back means checking out the previous tag (or, between releases, an earlier commit) and reinstalling it on that machine.

## Detect

- After a pull and rebuild, the symptoms in [injection-failure.md](injection-failure.md) appear: screenshots are captured but nothing lands in the terminal, or diagnostics such as `watcher.open_failed` or `applescript.error` appear that did not before.
- `hotshot` does not show a menu-bar icon, or logs no `app.launched` event.
- CI on `main` is red for the commit that was built (`gh run list --repo hivecommons/hotshot --branch main`).

## Contain

1. Find the last good version: list tags with `git tag --sort=-v:refname` and pick the previous release tag. Between releases, use `git log --oneline` or the last green commit of CI on `main`.
2. Check out the previous tag and rebuild. Use a detached checkout so your branch is untouched:
   ```sh
   git fetch origin
   git checkout <previous-tag>   # e.g. v0.1.0; or <good-sha> between releases
   swift build -c release
   ```
3. Reinstall it, matching how it was installed originally:
   - Binary: `sudo cp .build/release/hotshot /usr/local/bin/`
   - App bundle: `scripts/bundle.sh --install` (stops any running instance, replaces `/Applications/Hotshot.app`, relaunches)
   - Linux / Windows: re-run `linux/install.sh` or `windows/install.ps1` from the good checkout.
   - Homebrew (`brew install hivecommons/hive/hotshot`): the tap formula builds only the current tagged release from source, so `brew uninstall hotshot` and install the previous tag from a source checkout as above until the tap is fixed.
4. Quit and relaunch hotshot so the old process is not still running.

## Verify

1. Relaunch with `HOTSHOT_VERBOSE_LOGGING=1` and confirm `app.launched`, then `watcher.started`.
2. Confirm the installed app reports the expected release: `CFBundleShortVersionString` in `Hotshot.app/Contents/Info.plist` is derived by `scripts/bundle.sh` from the git tag (`v0.1.0` gives `0.1.0`), and `CFBundleVersion` is the full `git describe` string.
3. Take a screenshot with the target terminal focused. The `watcher.new_screenshot` (or `pasteboard.loaded`) event appears with no error after it, and the path or image lands in the terminal.

## Fix forward

- Do not skip or weaken a safety check (quarantine skip, control-character or shell-metacharacter refusal) to restore behavior; those refusals are deliberate.
- Open an issue with the commit range, the platform, and the diagnostic event names seen. Do not attach screenshot paths or clipboard contents, and review verbose logs first because they can contain local paths.
- Once a fix has merged, `git checkout main && git pull`, rebuild, and reinstall.

After the incident is resolved, record it using [postmortem-template.md](postmortem-template.md).
