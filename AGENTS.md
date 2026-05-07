# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a pure Xcode project — open `BrewMenu.xcodeproj` in Xcode and run with ⌘R. No CLI build scripts or package managers are used.

```bash
# Build from CLI (both targets):
xcodebuild -project BrewMenu.xcodeproj -scheme BrewMenu -configuration Debug build

# Archive for distribution:
xcodebuild -project BrewMenu.xcodeproj -scheme BrewMenu -configuration Release archive
```

```bash
# Run unit tests:
xcodebuild -project BrewMenu.xcodeproj -scheme BrewMenu -destination 'platform=macOS' -only-testing:BrewMenuTests test
```

The `BrewMenuTests` target contains 153 Swift Testing unit cases across 18 suites (145 `@Test` declarations; 3 of them are `@Test(arguments:)` parameterized tests that expand to 11 cases at runtime):
`BrewError` · `BrewError Supplemental` · `JSON Parsing` · `BrewService` · `BrewService Supplemental` · `AppSettings` · `UpgradeEngine` · `UpgradeEngine Supplemental` · `NotificationService Content` · `NotificationService Content Supplemental` · `NotificationService Delivery` · `AuthorizationService` · `AuthorizationService Supplemental` · `GreedyMode` · `SudoMonitor` · `SudoMonitor Supplemental` · `AutoScheduler` · `AutoScheduler Supplemental`

**Available mock helpers** (all `private` in `BrewMenuTests.swift`):
- `MockBrewCommandRunner` (class) — enqueue scripted responses, inspect `executedCommands`
- `MockSettingsStore` (class) — in-memory `SettingsStore`, thread-safe
- `MockCoordinator` (class) — records `transitionHistory` and `checkModes`
- `MockConfig` (struct) — lightweight `BrewConfiguration` value type for tests that don't need observation
- `MockBrewService` (class) — implements `BrewServiceProtocol`; enqueue scripted outdated/upgrade/stillOutdated results
- `MockNotificationService` (class) — implements `NotificationServiceProtocol`; records all notification calls for assertion

**Testing note — DistributedNotificationCenter:** delivery goes through the system daemon and is non-deterministic in XCTest hosts. `SudoMonitor` exposes two test-only entry points that bypass the notification path:
- `simulateHelperStarted(pid:)` — runs the lineage check and transitions state directly
- `simulateHelperFinished(pid:)` — removes the PID from activePIDs and calls handleMonitorResult

**Test host note:** `BrewMenuApp.init()` guards against `XCTestBundlePath` in the environment before the single-instance check, preventing a crash when the installed app is already running while tests execute.

## Architecture

**Two app targets:**
- `BrewMenu` — the menu bar app
- `BrewMenuAskPass` — a standalone subprocess that presents the password dialog; set as `SUDO_ASKPASS` when invoking `brew upgrade` with `sudo`

**Central coordinator pattern:** `AppCoordinator` owns all mutable UI state and orchestrates the three subsystems. Views receive a `BrewMenuCoordinating` protocol reference (never the concrete type). Subsystems receive a narrower `BrewStatusManager` protocol — they can push state transitions but cannot invoke user-facing actions.

```
AppCoordinator (@Observable @MainActor)
├── AutoScheduler       — timer lifecycle, PowerNap/wake handling
├── UpgradeEngine       — sequential upgrade queue, cancellation
├── SudoMonitor         — DistributedNotification bridge to AskPass helper
└── NetworkMonitor      — NWPathMonitor wrapper; injected into AutoScheduler so offline auto-scans skip silently
```

**State machine:** `AppStatus` drives UI rendering:
`idle → scanning → outdated → updating → authorizing → idle`

`AppStatus.error` is a terminal state requiring user intervention (e.g., brew not found).

## Authorization Flow

This is the most non-obvious part of the codebase.

1. `UpgradeEngine` runs `brew upgrade` with `sudo --askpass /path/to/BrewMenuAskPass`
2. **AskPass** launches as a subprocess, immediately posts `helperStarted` to `DistributedNotificationCenter` with its own PID, then enters `CFRunLoopRun()` — blocking silently
3. **SudoMonitor** (main app) receives `helperStarted`, validates the PID lineage via `sysctl` (must be: Helper → sudo → brew), transitions app to `.authorizing`, and shows a system notification
4. When the user taps the notification action, `SudoMonitor.triggerAuthorizationUI()` posts a PID-specific `triggerName` notification to the helper
5. **AskPass** wakes from `CFRunLoopRun()`, shows the `NSAlert` password dialog, posts `helperFinished` (so the main app can exit `.authorizing` while sudo is still reading the password), then prints the password to stdout and exits
6. `sudo` reads the password from stdout and proceeds
7. The timeout is managed entirely by `SudoMonitor` (default 5 min): on expiry it posts `cancelName`, causing AskPass to `exit(1)`, which makes sudo fail

**Security invariants:**
- The password never enters the main app's memory
- `DistributedNotificationCenter` is world-readable, but PID lineage validation prevents spoofing
- Spawned process PIDs are tracked in `RealBrewCommandRunner.registry` (`ActiveProcesses`, a lock-guarded set of `pid_t`). Processes are launched via `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, which atomically places each child in its own process group (PGID = PID) at spawn time. On cancel or app exit, `terminateAll()` sends `SIGINT` to each process group (`kill(-pid, SIGINT)`), mimicking a terminal Control-C so brew can clean up locks and partial files. If any processes remain after 5 seconds, it escalates to `SIGKILL`. This does not affect PPID, so SudoMonitor's sysctl lineage check is unaffected.

## Key Patterns

**Settings observation without explicit callbacks:** `AutoScheduler.armTimer()` uses `withObservationTracking` to subscribe to `AppSettings` changes. When any tracked property mutates, the closure posts a `Task { @MainActor in self.armTimer() }` — no delegate or notification needed.

**PowerNap exclusion:** `screensDidWakeNotification` only fires on real user-visible wakes, not dark wakes. The timer is invalidated on sleep and rebuilt on wake. If the elapsed time since last fire exceeds the configured interval, a scan fires immediately before re-arming.

**Pipe deadlock prevention:** `BrewCommandRunner.execute()` uses `readabilityHandler` (async, streaming) instead of `readDataToEndOfFile()` (blocks until EOF) to avoid deadlocking when brew output exceeds the 64 KB pipe buffer. All buffer mutations are serialized through a private `ioQueue`.

**Pre-upgrade skip logic:** Before upgrading each package, `UpgradeEngine` calls `brewService.checkIfPackageIsStillOutdated()`. If the package was already upgraded externally (e.g., in Terminal), it's skipped and counted as an external success in the result notification.

## Notification Names (shared across targets)

Defined in `BrewMenu/Models/BrewMenuShared.swift` — this file is compiled into **both** targets:
- `com.whoami.brewmenu.helper.started` / `.finished` — process lifecycle signals
- `com.whoami.brewmenu.trigger.<pid>` / `.cancel.<pid>` — per-session UI control
