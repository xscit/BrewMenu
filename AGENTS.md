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

The `BrewMenuTests` target contains 214 Swift Testing unit cases across 12 suites (several `@Test(arguments:)` parameterized tests expand the declaration count):
`AppCoordinator` · `AppSettings` · `AuthorizationService` · `AutoScheduler` · `BrewError` · `BrewService` · `CleanupSchedule` · `GreedyMode` · `NotificationService Content` · `NotificationService Delivery` · `SudoMonitor` · `UpgradeEngine`

Each suite lives in its own file (`AppCoordinatorTests.swift`, `BrewErrorTests.swift`, etc.). Shared test infrastructure is in `TestFixtures.swift`.

**Available mock helpers** (defined in `TestFixtures.swift`):
- `MockBrewCommandRunner` (class) — enqueue scripted responses, inspect `executedCommands`
- `MockSettingsStore` (class) — in-memory `SettingsStore`, thread-safe
- `MockCoordinator` (class) — records `transitionHistory` and `checkModes`; implements `BrewStatusManager` (not `BrewMenuCoordinating`)
- `MockConfig` (struct) — lightweight `BrewConfiguration` value type for tests that don't need observation (`cleanupSchedule`, `cleanupPruneDays`, `greedyMode`, `authTimeout`)
- `MockBrewService` (class) — implements `BrewServiceProtocol`; enqueue scripted outdated/upgrade/stillOutdated results
- `MockNotificationService` (class) — implements `NotificationServiceProtocol`; records all notification calls for assertion

**Testing note — DistributedNotificationCenter:** delivery goes through the system daemon and is non-deterministic in XCTest hosts. `SudoMonitor` exposes two test-only entry points that bypass the notification path:
- `simulateHelperStarted(pid:)` — runs the lineage check and transitions state directly
- `simulateHelperFinished(pid:)` — removes the PID from activePIDs and calls handleMonitorResult

**Test host note:** `BrewMenuApp.init()` guards against `XCTestBundlePath` in the environment before the single-instance check, preventing a crash when the installed app is already running while tests execute.

**AppCoordinator init side-effects:** `AppCoordinator.init` immediately fires `Task { await check(mode: .initial) }`, `autoScheduler.start()`, and `cleanupScheduler.start()`. In `AppCoordinatorTests`, always enqueue `MockBrewService` responses *after* `makeCoordinator` returns (the helper drains the initial task with `Task.yield()` loops). Enqueueing before init means the initial scan consumes those entries first.

## Architecture

**Two app targets:**
- `BrewMenu` — the menu bar app
- `BrewMenuAskPass` — a standalone subprocess that presents the password dialog; set as `SUDO_ASKPASS` when invoking `brew upgrade` with `sudo`

**Central coordinator pattern:** `AppCoordinator` owns all mutable UI state and orchestrates the three subsystems. Views receive a `BrewMenuCoordinating` protocol reference (never the concrete type). Subsystems receive a narrower `BrewStatusManager` protocol — they can push state transitions but cannot invoke user-facing actions.

```
AppCoordinator (@Observable @MainActor)
├── AutoScheduler       — timer lifecycle, PowerNap/wake handling (scan only)
├── CleanupScheduler    — NSBackgroundActivityScheduler for everyNDays cleanup; wake-based fallback via lastCleanupDate
├── UpgradeEngine       — sequential upgrade queue, cancellation
├── SudoMonitor         — DistributedNotification bridge to AskPass helper
└── NetworkMonitor      — NWPathMonitor wrapper; injected into AutoScheduler so offline auto-scans skip silently
```

**State machine:** `AppStatus` drives UI rendering:
`idle → scanning → outdated → updating → authorizing → idle`

`AppStatus.error` is a terminal state requiring user intervention (e.g., brew not found).

**Injectable seams for testing:** Three interfaces exist solely to make deterministic unit tests possible — they are not abstractions over real complexity:
- `NetworkConnectivityProvider` (`NetworkMonitor`) — lets `AutoSchedulerTests` inject a fake offline/online state without a real network interface
- `ClockProvider` (`SystemClock`) — lets `AutoSchedulerTests` control `Date.now` to simulate elapsed time without real `sleep`
- `ppidProvider` (`SudoMonitor`) — lets `SudoMonitorTests` bypass `sysctl` and supply a fake PID lineage

## Authorization Flow

This is the most non-obvious part of the codebase.

1. `UpgradeEngine` runs `brew upgrade` with `sudo --askpass /path/to/BrewMenuAskPass`
2. **AskPass** launches as a subprocess, immediately posts `helperStarted` to `DistributedNotificationCenter` with its own PID, then enters `CFRunLoopRun()` — blocking silently
3. **SudoMonitor** (main app) receives `helperStarted`, validates the PID lineage via `sysctl` (must be: Helper → sudo → brew), transitions app to `.authorizing`, and shows a system notification
4. When the user taps the notification action, `SudoMonitor.triggerAuthorizationUI()` posts a PID-specific `triggerName` notification to the helper
5. **AskPass** wakes from `CFRunLoopRun()`, shows the `NSAlert` password dialog, posts `helperFinished` (so the main app can exit `.authorizing` while sudo is still reading the password), then prints the password to stdout and exits
6. `sudo` reads the password from stdout and proceeds
7. The timeout is managed entirely by `SudoMonitor` (default 5 min, configurable 1–60 min): on expiry it posts `cancelName`, causing AskPass to `exit(1)`, which makes sudo fail

**Security invariants:**
- The password never enters the main app's memory
- `DistributedNotificationCenter` is world-readable, but PID lineage validation prevents spoofing
- Spawned process PIDs are tracked in `RealBrewCommandRunner.registry` (`ActiveProcesses`, a lock-guarded set of `pid_t`). Processes are launched via `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, which atomically places each child in its own process group (PGID = PID) at spawn time. On cancel or app exit, `terminateAll()` sends `SIGINT` to each process group (`kill(-pid, SIGINT)`), mimicking a terminal Control-C so brew can clean up locks and partial files. If any processes remain after 5 seconds, it escalates to `SIGKILL`. This does not affect PPID, so SudoMonitor's sysctl lineage check is unaffected.

## Logging

All subsystems log through `Log.<category>` (defined in `Logger.swift`), which wraps `os.Logger` via `BrewLogger`:

- **`debug` / `info`** — `os.Logger` only; not written to file. Use for internal flow details (startup, cancel, process management).
- **`notice` / `warning` / `error`** — written to both `os.Logger` and `~/Library/Logs/BrewMenu.log` via a background `DispatchQueue`. Visible in Console.app → Log Reports without streaming.

All dynamic interpolations use `privacy: .public` so content is readable in release builds. The log file contains no credentials — sudo passwords never pass through the main app (see Authorization Flow).

## Key Patterns

**Settings observation without explicit callbacks:** `AutoScheduler.armTimer()` uses `withObservationTracking` to subscribe to `AppSettings` changes. When any tracked property mutates, the closure posts a `Task { @MainActor in self.armTimer() }` — no delegate or notification needed.

**PowerNap exclusion:** `screensDidWakeNotification` only fires on real user-visible wakes, not dark wakes. The timer is invalidated on sleep and rebuilt on wake. If the elapsed time since last fire exceeds the configured interval, a scan fires immediately before re-arming.

**Cleanup scheduling (everyNDays):** `CleanupScheduler` delegates timing to `NSBackgroundActivityScheduler` (backed by the XPC Activity API), which lets macOS choose the optimal moment within the interval — no long-lived timer, no manual sleep/wake management. A `lastCleanupDate` stored in UserDefaults acts as a fallback: on startup and screen wake, `CleanupScheduler` compares elapsed time against `cleanupIntervalDays` and fires immediately if the background activity state was reset (e.g., after a system update). When the scheduler fires, it checks `coordinator.status`: if the app is scanning or upgrading (anything other than `.idle` or `.outdated`), it calls `completion(.deferred)` so macOS retries later rather than running cleanup concurrently. The `afterUpgrade` path runs through `UpgradeEngine → coordinator.cleanup()`, keeping all three trigger paths (post-upgrade, scheduled, manual) unified at `AppCoordinator.cleanup()`.

**Pipe deadlock prevention:** `BrewCommandRunner.execute()` uses `readabilityHandler` (async, streaming) instead of `readDataToEndOfFile()` (blocks until EOF) to avoid deadlocking when brew output exceeds the 64 KB pipe buffer. All buffer mutations are serialized through a private `ioQueue`.

**App-side package exclusions:** `AppSettings.pinnedPackages: Set<String>` stores package names to exclude. `AppCoordinator.runScan` filters the exclusion set out of every `getOutdatedPackages` result before writing to `outdatedPackages`. `pin(package:)` also immediately removes the package from the live `outdatedPackages` array (and transitions to `.idle` if the list becomes empty), so the menu reflects the change without waiting for the next scan. `brew pin` is never called — exclusions exist only in UserDefaults and have no side-effects on Homebrew.

**Pre-upgrade skip logic:** Before upgrading each package, `UpgradeEngine` calls `brewService.checkIfPackageIsStillOutdated()`. If the package was already upgraded externally (e.g., in Terminal), it's skipped and counted as an external success in the result notification.

**Notification consolidation — all upgrade errors go into the final summary:**
`UpgradeEngine.finishUpgrade()` no longer calls `showTransientError` for individual package failures. Instead it builds a `relevantFailedMessages: [String: String]` dict (package name → `error.userMessage`, filtered to packages still outdated after refresh) and passes it to `showUpgradeResult`. `upgradeResultContent` then renders each failed package as a per-line entry:
- Without reason: `❌ Failed: wget` (fallback, no error context available)
- With reason: `❌ wget (Network unavailable)` — covers all error types including network failures

This means every upgrade scenario produces at most **two** system notifications: `showUpdatesFound` (if auto-upgrade is off and updates were found) and `showUpgradeResult` (the final summary). The one exception is authorization flows, where `showAuthRequired` fires mid-upgrade because it carries an actionable "Authorize" button that the user must tap.

Notification count by scenario:
- Scan finds no updates (non-refresh mode) → **1** (Brew Ready)
- Updates found, auto-upgrade off → **1** (Updates Available — "can be updated")
- Updates found, auto-upgrade on, all succeed → **2** (Upgrading — "will be updated" + Brew Updated)
- Auto-upgrade on, batch with sudo, normal auth → **3** (Upgrading + Authorization Required + Brew Updated)
- Auto-upgrade on, Wi-Fi disconnects mid-batch → **2** (Upgrading + Upgrade Failed with per-package reasons)
- Auto-upgrade on, cancel mid-batch → **2** (Upgrading + Partial Upgrade, unstarted packages shown as ⏭️ Skipped)
- Scan fails (any mode, non-fatal) → **1** (Network Unavailable / Command Failed, no upgrade started)
- Fatal brew-not-found error → **1** (Homebrew Not Found, always fires — cannot be silenced)

**Per-category notification toggles:**
`NotificationService` holds a `weak var settings: AppSettings?`, injected by `AppCoordinator` at init. Each `show*` method checks the relevant toggle before scheduling — `showBrewNotFound` is the only method with no guard (fatal, always fires). Toggle-to-method mapping:
- `notifyOnScanResults` → `showNoUpdatesFound`, `showUpdatesFound`
- `notifyOnUpgradeResult` → `showUpgradeResult`
- `notifyOnAuthRequired` → `showAuthRequired`, `showAuthTimeout`
- `notifyOnErrors` → `showTransientError`

## Notification Names (shared across targets)

Defined in `BrewMenu/Models/BrewMenuShared.swift` — this file is compiled into **both** targets:
- `com.whoami.brewmenu.helper.started` / `.finished` — process lifecycle signals
- `com.whoami.brewmenu.trigger.<pid>` / `.cancel.<pid>` — per-session UI control
