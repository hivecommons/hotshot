# hotshot

Take a screenshot, and it lands in your terminal. That's it.

**hotshot** is a tiny app that watches for new screenshots and automatically injects them into whichever terminal session you were last using. Built for AI coding assistants like [Claude Code](https://claude.ai/code), GitHub Copilot CLI, aider, and OpenCode that accept image paths as input.

If you're like me, you use screenshots constantly to debug your work — a broken UI, a weird error message, a dashboard that doesn't look right. Normally you'd screenshot it, find the file, copy the path, switch to your terminal, paste it in. **hotshot** skips all of that — just take a screenshot the way you always do and it lands in your terminal.

## Platforms

| Platform | Form | Trigger | Install | Docs |
|---|---|---|---|---|
| **macOS** | Menu bar app (Swift, zero deps) | Native ⌘⇧3/4/5 + ⌃⌘⇧3/4 shortcuts (file/clipboard watcher) | [below](#install) | this page |
| **Linux** | Shell script (X11 & Wayland) | Hotkey you bind in your DE (e.g. Ctrl+Shift+Print) | `linux/install.sh` | [linux/README.md](linux/README.md) |
| **Windows** | PowerShell script (+ optional AutoHotkey v2) | Global hotkey (default Ctrl+Alt+H) → Snipping overlay | `windows\install.ps1` | [windows/README.md](windows/README.md) |

All platforms honor the same contract:

| | macOS | Linux | Windows |
|---|---|---|---|
| PNG saved to a known folder | ✅ | ✅ | ✅ |
| Clipboard: image | ✅ | ✅ | ✅ |
| Clipboard: plain-text path | ✅ | with CopyQ (single-owner clipboard otherwise) | ✅ |
| Clipboard: file URL / drop list | ✅ file URL | with CopyQ | ✅ file drop list |
| CLI detection (focused terminal's processes) | `ps -t <tty>` | `/proc` descendants | Win32_Process tree |
| Claude Code → typed `[path] ` | ✅ | ✅ | ✅ |
| Copilot CLI / aider / OpenCode → bare escaped path | ✅ backslash-escaped | ✅ backslash-escaped | quoted if spaces |
| Unknown CLI → bracketed default | ✅ | ✅ | ✅ |

The rest of this page documents the **macOS** app.

## What it looks like

**File mode (default, ⌘⇧3 / ⌘⇧4 / ⌘⇧5):**
1. You're working in Claude Code (or any AI CLI) in your terminal
2. You switch to a browser and spot a bug
3. Take a screenshot the way you always do
4. hotshot detects the new file and injects the path into your terminal session
5. Your AI assistant reads the image and starts helping

**Clipboard mode (⌃⌘⇧3 / ⌃⌘⇧4):**
1. Take a screenshot to clipboard (Control-Command-Shift instead of Command-Shift)
2. hotshot detects the new clipboard image and sends Ctrl-V to your terminal
3. No files created — the image goes straight from clipboard to your AI assistant

Clipboard mode is ideal for remote sessions (tmux, zellij, OpenShell) where there's no shared filesystem.

No dragging files around. No copy-pasting paths. No "here let me find where that screenshot went."

## Install

Requires macOS 13+ and Swift (comes with Xcode or Xcode Command Line Tools).

```bash
git clone https://github.com/hivecommons/hotshot.git
cd hotshot
swift build -c release
sudo cp .build/release/hotshot /usr/local/bin/
```

Then just run it:

```bash
hotshot
```

A small camera icon appears in your menu bar — that's hotshot running. It stays out of your way until you need it.

> Tip: Run `hotshot &` to background it so it doesn't hold your terminal.

### First-time setup

macOS will ask for Accessibility permission the first time — this lets hotshot type the path into your terminal. Grant it in System Settings > Privacy & Security. You only have to do this once.

## How it works

hotshot remembers which terminal you last clicked on. It supports two injection modes:

**File mode** (on by default):
1. macOS saves the screenshot to your configured folder (Desktop, Downloads, etc.)
2. hotshot detects the new file within a couple of seconds
3. Detects which CLI is running in the target terminal session (via its tty) and injects the matching format — `[bracketed]` for Claude Code, a bare shell-escaped path for GitHub Copilot CLI/aider/OpenCode — and also loads the clipboard with the image + file URL + plain-text path so you can ⌘V it anywhere

**Clipboard mode** (on by default):
1. You take a screenshot to clipboard with ⌃⌘⇧3 or ⌃⌘⇧4
2. hotshot detects the new image on the clipboard, saves it to your screenshot folder as `hotshot-YYYYMMDD-HHMMSS.png`, and rewrites the clipboard with the image **plus** the file's plain-text path and file URL
3. Sends Ctrl-V to your last active terminal — Claude Code reads the image data; CLIs like GitHub Copilot CLI get the file path when you paste as text (⌘V)

Both modes bring the terminal back to the front automatically. No servers, no browser extensions.

## Configuring

Click the camera icon in your menu bar. Everything is configurable:

| Option | Default | What it does |
|--------|---------|--------------|
| **Auto-focus terminal** | On | Brings your terminal to the front after pasting the path |
| **Auto-press Return** | Off | Sends Enter after the path (so your CLI processes it immediately) |
| **Show notifications** | Off | Desktop notification after each capture |
| **Auto-inject new screenshots (file)** | On | Watches your screenshot folder for new files and auto-injects the path |
| **Auto-inject from clipboard (⌃⌘⇧3/4)** | On | Watches clipboard for new images and sends Ctrl-V to your terminal |
| **Inject last screenshot** | — | Menu action: injects the most recent screenshot file path |
| **Inject clipboard image** | — | Menu action: sends Ctrl-V to paste current clipboard image |
| **Change screenshot folder** | Your macOS default | Pick any folder — opens a standard folder picker |

## Works with these terminals

- **iTerm2** (recommended — uses native AppleScript for reliable injection)
- Terminal.app
- Kitty
- Alacritty
- Warp
- Ghostty

## Works with these AI assistants

Any CLI tool that accepts image file paths as input:

- [Claude Code](https://claude.ai/code)
- [GitHub Copilot CLI](https://githubnext.com/projects/copilot-cli)
- [aider](https://aider.chat)
- [OpenCode](https://github.com/anthropics/opencode)
- Any tool where you can paste a file path and it reads the image

## FAQ

**Does it conflict with the Mac's built-in screenshot shortcuts?**
No — it works *with* them. Your normal ⌘⇧3/4/5 shortcuts work exactly as before (file mode). And ⌃⌘⇧3/4 clipboard shortcuts work with clipboard mode. hotshot watches for the results and injects automatically.

**I took a screenshot and nothing appeared in my terminal.**
Make sure hotshot is running (look for the camera icon in your menu bar). Also make sure you've clicked on a terminal window at least once since launching hotshot — it needs to know which terminal to target.

**Where do the screenshots go?**
By default, wherever your Mac saves screenshots (usually Desktop or Downloads). hotshot reads your macOS screenshot location setting automatically. You can override it from the menu bar > "Change screenshot folder..."

**What format is the path injected in?**
hotshot inspects the processes on the target terminal session's tty (iTerm2 and Terminal.app) and picks the format that CLI understands: Claude Code gets `[/path/to/screenshot.png]`, while GitHub Copilot CLI, aider, and OpenCode get a bare backslash-escaped path (what Finder drag-and-drop inserts). If the CLI can't be determined, the historical bracketed format is used. The clipboard simultaneously carries the PNG image, a file URL, and the escaped plain-text path, so pasting (⌘V, or Ctrl-V in Claude Code) works everywhere.

**Does it work over SSH / remote sessions?**
Clipboard mode works with remote sessions (tmux, zellij, OpenShell) as long as the clipboard is shared between your Mac and the remote terminal. For sessions without shared clipboard, check out [clipssh](https://github.com/samuellawrentz/clipssh) or [clipaste](https://github.com/hqhq1025/clipaste).

**Can I use it with VS Code's integrated terminal?**
Not yet — VS Code's terminal isn't a standalone app. For VS Code, try [vscode-terminal-image-paste](https://github.com/cybersader/vscode-terminal-image-paste).

**What does hotshot log, and where does it go?**
Diagnostics stay local (Console.app / `stderr`, never sent anywhere) and normally omit screenshot directory paths, filenames, generated AppleScript, and clipboard contents — just stable event names and severities, e.g. `Hotshot [WARN] injection.control_chars_refused`. Set `HOTSHOT_VERBOSE_LOGGING=1` before launching hotshot (or the Linux/Windows capture scripts) to include the redacted values for local debugging.

## Technical details

A small Swift package (`HotshotCore` for pure logic, `HotshotApp` for the watchers and terminal injection, and the `hotshot` executable target), compiled to a native macOS binary. Zero dependencies — no frameworks, no packages, no runtime requirements. Just Apple's built-in APIs:

- `DispatchSource` file system watcher for auto-detecting new screenshots
- `NSPasteboard` polling for clipboard image detection
- `NSWorkspace` notifications to track terminal focus
- `NSAppleScript` to inject paths and keystrokes into terminal sessions
- `UserDefaults` to persist your preferences

## License

Apache-2.0 — see [LICENSE](LICENSE).
