# BrewMenu

A native macOS menu bar app for [Homebrew](https://brew.sh). Checks for outdated formulae and casks on a schedule, runs upgrades sequentially, and asks for your password only when a cask actually needs `sudo` — no daemon, no persistent root privileges.

> **Status:** early release (current version: `0.6.0`). Used daily by the author; expect rough edges and occasional breaking changes until `1.0`.

---

## Why

`brew upgrade` is fine, but it's easy to forget. The alternatives either run as a privileged background daemon (overkill, uncomfortable) or just shell out to `brew` and surface its raw output (no real lifecycle handling). BrewMenu sits in between: it lives in the menu bar, runs unprivileged, and only escalates to `sudo` for the specific cask installer that requires it — through an isolated AskPass subprocess that the main app never has password access to.

## Features

- **Scheduled checks** — every 1 / 6 / 12 / 24 hours, or a custom interval (1 minute – 7 days), or manual only.
- **Wake-up catch-up** — if the scan window elapsed during sleep, BrewMenu re-runs immediately on wake.
- **PowerNap-aware** — does nothing while the screen is asleep; the timer is rebuilt when the display wakes.
- **Sequential upgrade queue** — packages are upgraded one at a time so a single failure doesn't take down the rest.
- **Pre-upgrade skip** — if a package was already upgraded externally (e.g., from Terminal), it's detected and skipped, not re-run.
- **Greedy modes** — supports `--greedy`, `--greedy-auto-updates`, and `--greedy-latest` for casks that auto-update themselves.
- **Optional auto-cleanup** — runs `brew cleanup --prune=all` after a successful batch.
- **Cancellable at any point** — `Esc` aborts the active scan, upgrade, or pending authorization. Running `brew` processes (and their `curl` / `git` children) are sent `SIGINT`, then `SIGKILL` after 5 seconds if they refuse to exit.
- **Localized notifications** — English and Simplified Chinese. Strings live in `BrewMenu/Localizables/*.xcstrings`.

## Authorization model

This is the part that most apps in this space get wrong, so it's worth describing.

When `brew upgrade` hits a cask that requires `sudo`, BrewMenu does **not** run brew as root. Instead:

1. `brew upgrade` is invoked with `sudo --askpass /path/to/BrewMenuAskPass`.
2. **BrewMenuAskPass** is a tiny separate executable. It launches as a subprocess, posts `helperStarted` to `DistributedNotificationCenter` with its own PID, and blocks in `CFRunLoopRun()`.
3. The main app receives `helperStarted`, validates the PID lineage via `sysctl` (must be: AskPass → sudo → brew), transitions to the `authorizing` state, and posts a system notification.
4. When you tap the notification action, the main app posts a PID-specific `trigger` notification back to AskPass.
5. AskPass wakes up, shows a native `NSAlert` password dialog, then prints the password to stdout and exits.
6. `sudo` reads the password from AskPass's stdout. The main app never sees it.

PID lineage validation prevents a malicious process from spoofing a `helperStarted` notification, since it would need to fake a process tree the kernel exposes. The password lives only in the short-lived AskPass subprocess and goes directly to `sudo` — it never crosses an IPC boundary.

If you don't enter the password within the timeout (default 5 minutes), AskPass exits, `sudo` fails, that one package is marked `Skipped`, and the queue continues with the next package.

## Install

### Homebrew

```bash
brew tap xscit/brewmenu https://github.com/xscit/BrewMenu
brew install --cask brewmenu
```

### Manual

Download `BrewMenu.zip` from the [Releases page](https://github.com/xscit/BrewMenu/releases), unzip, and drag `BrewMenu.app` into `/Applications`.

### Build from source

Open `BrewMenu.xcodeproj` in Xcode and run with ⌘R. Or from the command line:

```bash
xcodebuild -project BrewMenu.xcodeproj -scheme BrewMenu -configuration Release build
```

There is no SwiftPM manifest and no external dependencies — it's a plain two-target Xcode project.

## Requirements

- macOS 14.0 or later
- Homebrew installed at `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel)
- Xcode 16+ to build

## Architecture

A short tour, since this is a public repo and someone is going to want to read the code.

```
AppCoordinator (@Observable @MainActor)
├── AutoScheduler   — timer lifecycle, sleep/wake, PowerNap
├── UpgradeEngine   — sequential upgrade queue, cancellation, pre-upgrade skip
├── SudoMonitor     — DistributedNotification bridge to AskPass
└── NetworkMonitor  — NWPathMonitor wrapper; offline auto-scans skip silently
```

State machine: `idle → scanning → outdated → updating → authorizing → idle`. `error` is terminal and requires user intervention (e.g., brew not on PATH).

Process control lives in `BrewCommandRunner`. Children are spawned with `posix_spawn` + `POSIX_SPAWN_SETPGROUP` so each `brew` invocation is the leader of its own process group; cancellation sends signals to the group (`kill(-pid, SIGINT)`), which catches `curl` and `git` descendants too.

For more detail — file layout, test suite, key invariants — see [`AGENTS.md`](AGENTS.md).

## Testing

```bash
xcodebuild -project BrewMenu.xcodeproj -scheme BrewMenu \
  -destination 'platform=macOS' -only-testing:BrewMenuTests test
```

The test target uses Swift Testing and covers the upgrade engine, scheduler, authorization flow, notification content, and command parsing. See `AGENTS.md` for the suite breakdown.

For end-to-end testing without touching real packages, `Tools/brew_lab/` provisions a local Homebrew tap with dummy formulae and casks (including ones that require `sudo`) so you can exercise the full flow safely. See [`Tools/brew_lab/brew_lab.md`](Tools/brew_lab/brew_lab.md).

## Contributing

Issues and pull requests welcome. Before submitting a non-trivial change, please open an issue first so we can agree on direction.

When working on the code, `AGENTS.md` documents the coordinator pattern, the authorization invariants, and a few non-obvious gotchas (pipe deadlocks, Settings observation, PowerNap exclusion). Read it before changing the upgrade or auth path.

## License

[MIT](LICENSE).
