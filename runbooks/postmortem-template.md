# Postmortem template

Copy this file into an issue after any regression that reached users or any near miss with a safety check (for example a build that bypassed the quarantine skip or the control-character refusal). Keep it blameless: describe what the system allowed, not who made the change.

Do not attach screenshot paths, clipboard contents, or unreviewed verbose logs. They can contain local paths.

## Summary

One or two sentences: what broke, on which platform (macOS, Linux, Windows), and how long it lasted.

## Impact

- Who was affected: users who built or installed commits `<first-bad-sha>` through `<last-bad-sha>`.
- Symptom, using the event names from [injection-failure.md](injection-failure.md) (for example `watcher.open_failed`, `applescript.error`).
- Whether any safety refusal was bypassed. If so, say so plainly.

## Timeline

hotshot has no auto-updater, so a bad change only reaches a machine when its user pulls and rebuilds. Record times for:

| When (UTC) | Event |
|---|---|
| | Bad commit merged to `main` |
| | First report or first red CI run |
| | Cause identified |
| | Fix merged, or rollback guidance published ([release-rollback.md](release-rollback.md)) |

## Cause

What changed, and why the checks that ran (`swift test`, the Linux and Windows suites, shellcheck) did not catch it.

## What went well / what did not

- Detection: did a diagnostic event or CI point at the cause quickly?
- Recovery: did [release-rollback.md](release-rollback.md) work as written?

## Follow-ups

Each item needs an owner and a linked issue. Prefer a test or CI gate over a documentation-only fix.

- [ ] Regression test covering the failure
- [ ] Runbook updated where a step was missing or wrong
