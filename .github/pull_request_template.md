## Summary

<!-- What does this PR change, and why? Describe any user-visible change and which platforms it affects (macOS app, Linux script, Windows script). -->

Fixes #<!-- issue number, if this PR resolves one -->

## Validation

<!-- Which checks did you run, and on which OS? If you could not run a platform-specific check, say so and describe the manual validation you did instead. -->

## Checklist

See [CONTRIBUTING.md](https://github.com/hivecommons/hotshot/blob/main/CONTRIBUTING.md) for the exact commands and coverage floors.

- [ ] The checks for every platform this change touches pass locally (`swift test --enable-code-coverage`, `bash scripts/shell-coverage.sh`, ShellCheck, PSScriptAnalyzer, Pester)
- [ ] New or changed lines are covered by tests (CI enforces per-module coverage floors for Swift, shell and PowerShell)
- [ ] Changes to path injection or CLI detection keep macOS, Linux and Windows aligned with the README contract
- [ ] A renamed or new diagnostic event is reflected in `runbooks/` in this PR
- [ ] Commits are signed off (`git commit -s`)
