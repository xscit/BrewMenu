# Changelog

## [0.6.1] - 2026-05-12
- **Enhanced Status Header**: Added date to the "Last Checked" display to provide better context for multi-day sessions.
- **Keyboard Shortcuts**: Remapped the menu cancel action to `⌘ .` (standard macOS combination) to resolve conflicts with system menu behavior.
- **Code Hygiene & Quality**:
    - Integrated SwiftLint for automated code style enforcement and applied project-wide fixes.
    - Removed redundant Foundation imports and enabled strict unused import linting rules.
- **Bug Fixes**:
    - Fixed an issue where the automatic scan on system wake would fail to trigger if the next scheduled scan had never been reached.

## [0.6.0] - 2026-05-07
- First public release on GitHub.
