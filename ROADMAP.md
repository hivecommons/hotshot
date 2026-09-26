# Hotshot Roadmap

Hotshot is a small cross-platform bridge from screenshots to AI terminals. This
roadmap records the near-term direction so contributors can align work across
the macOS app, Linux script, and Windows helper.

## Recently shipped

- macOS, Linux, and Windows screenshot-to-terminal flows with CLI-aware text
  injection for Claude Code, GitHub Copilot CLI, aider, and opencode.
- Clipboard enrichment with image data, file URLs, and shell-escaped text paths.
- Hermetic Linux and Windows tests plus extracted `HotshotCore` helpers for
  shared macOS decision logic.

## Near term

1. **Package distribution:** publish first-class install paths beyond manual
   scripts, starting with Homebrew and documenting follow-on candidates such as
   winget and distro packages.
2. **Cross-platform parity:** keep Linux Wayland/X11 and Windows behavior aligned
   with macOS for clipboard modes, typed injection, warning paths, and safe
   degradation when helper tools are missing.
3. **More terminal and agent targets:** expand detection and examples for
   terminals and AI CLIs as the ecosystem changes, while keeping unknown targets
   on safe, explicit fallback behavior.

## Non-goals for now

- Full screen recording, GIF capture, or video editing workflows.
- Remote desktop or SSH session discovery beyond terminal/tmux-oriented flows.
- Cloud storage or hosted screenshot processing; Hotshot should remain local by
  default.
