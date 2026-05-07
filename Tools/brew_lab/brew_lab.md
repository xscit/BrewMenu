# Brew Lab

A throwaway local Homebrew tap for testing BrewMenu against real `brew` flows without touching the packages you actually depend on.

## What it provisions

A `local/test` tap with five dummy packages:

- **lab-f1, lab-f2** — plain formulae
- **lab-c1** — plain cask
- **lab-sudo-c, lab-sudo-c2** — casks whose upgrade requires `sudo` (they invoke `sudo touch` against `/Library/Logs/brew_lab_sudo_*.log` in their preflight). Two of them so you can exercise back-to-back authorization in a single batch.

## Usage

### Start the lab

Installs all packages at `v1.0.0`, then bumps the formula/cask definitions to `v1.1.0` so they show up in `brew outdated`:

```bash
./Tools/brew_lab/brew_lab.sh start
```

### Tear it down

Uninstalls every lab package, removes the `local/test` tap, and cleans up the sudo log files (will prompt for your password):

```bash
./Tools/brew_lab/brew_lab.sh finish
```

### Check state

```bash
./Tools/brew_lab/brew_lab.sh status
```

> **Apple Silicon only.** The script assumes Homebrew is installed at `/opt/homebrew`.
