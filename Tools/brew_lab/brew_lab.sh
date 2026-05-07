#!/bin/bash
# set -x

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

# BrewMenu Local Integration Lab
# This script manages a set of local formulae and casks in the local/test tap.

# Check if brew is installed, Only support Homebrew on Apple Silicon
[ -d "/opt/homebrew" ] || {
  echo "Error: Brew not found"
  exit 1
}

BREW_BIN="/opt/homebrew/bin/brew"
TAP_NAME="local/test"
TAP_PATH=$(/opt/homebrew/bin/brew --repository)/Library/Taps/local/homebrew-test
FORMULA_DIR="$TAP_PATH/Formula"
CASK_DIR="$TAP_PATH/Casks"
FORMULAE=("lab-f1" "lab-f2")
CASKS=("lab-c1" "lab-sudo-c" "lab-sudo-c2")

# Helper to create a unique dummy tarball source for each version/package
prepare_source() {
  local version=$1
  local name=$2
  local payload_dir="/tmp/brew_lab_payload_$name"
  local source_tgz="/tmp/brew_lab_${name}_${version}.tar.gz"

  mkdir -p "$payload_dir"
  echo "Version: $version" >"$payload_dir/VERSION"
  # Create a small dummy script
  echo "#!/bin/sh" >"$payload_dir/dummy"
  echo "echo 'Running $name version $version'" >>"$payload_dir/dummy"
  chmod +x "$payload_dir/dummy"

  # Tar it up to create a unique file with a unique SHA256
  tar -czf "$source_tgz" -C "$payload_dir" .
  local sha
  sha=$(shasum -a 256 "$source_tgz" | awk '{print $1}')
  echo "$source_tgz|$sha"
}

# Helper to create a dummy formula
create_formula() {
  local name=$1
  local version=$2
  local source_data=$3
  local source_path
  source_path=$(echo "$source_data" | cut -d'|' -f1)
  local sha
  sha=$(echo "$source_data" | cut -d'|' -f2)
  local class_name
  class_name=$(echo "$name" | ruby -e 'puts STDIN.read.split("-").map(&:capitalize).join')

  mkdir -p "$FORMULA_DIR"
  cat <<EOF >"$FORMULA_DIR/$name.rb"
class $class_name < Formula
  desc "Lab Test Formula $name"
  homepage "https://example.com"
  url "file://$source_path"
  version "$version"
  sha256 "$sha"

  def install
    bin.install "dummy" => "$name"
  end
end
EOF
}

# Helper to create a dummy cask
create_cask() {
  local name=$1
  local version=$2
  local sudo_req=$3
  local source_data=$4
  local source_path
  source_path=$(echo "$source_data" | cut -d'|' -f1)
  local sha
  sha=$(echo "$source_data" | cut -d'|' -f2)

  mkdir -p "$CASK_DIR"
  cat <<EOF >"$CASK_DIR/$name.rb"
cask "$name" do
  version "$version"
  sha256 "$sha"
  url "file://$source_path"
  name "$name"
  desc "Lab Test Cask $name"
  homepage "https://example.com"

  artifact "dummy", target: "/tmp/brew_lab_$name"
  
  $([ "$sudo_req" == "true" ] && echo "preflight do
    if version == \"1.1.0\"
      ohai \"[LAB] Triggering Sudo for $name (v1.1.0)...\"
      system_command \"sudo\", args: [\"touch\", \"/Library/Logs/brew_lab_sudo_$name.log\"], must_succeed: true
    end
  end")
end
EOF
}

status() {
  echo "=== Brew Lab Status ==="
  $BREW_BIN outdated --json
}

start() {
  echo "🚀 Starting Professional Lab Environment..."

  # Create local tap
  $BREW_BIN tap-new $TAP_NAME 2>/dev/null || {
    echo "Error: Failed to create local tap, maybe execute finish first?"
    exit 1
  }

  # 1. Install v1.0.0
  for f in "${FORMULAE[@]}"; do
    data=$(prepare_source "1.0.0" "$f")
    create_formula "$f" "1.0.0" "$data"
    echo "Installing $f (v1.0.0)..."
    $BREW_BIN install -q --formula "$TAP_NAME/$f" || true
  done

  for c in "${CASKS[@]}"; do
    [[ "$c" == "lab-sudo-c" || "$c" == "lab-sudo-c2" ]] && sudo_req="true" || sudo_req="false"
    data=$(prepare_source "1.0.0" "$c")
    create_cask "$c" "1.0.0" "$sudo_req" "$data"
    echo "Installing $c (v1.0.0)..."
    $BREW_BIN install -q --cask "$TAP_NAME/$c" || true
  done

  # 2. Bump definitions to v1.1.0 to trigger 'outdated'
  echo "✨ Bumping definitions to v1.1.0 to trigger updates..."
  for f in "${FORMULAE[@]}"; do
    data=$(prepare_source "1.1.0" "$f")
    create_formula "$f" "1.1.0" "$data"
  done
  for c in "${CASKS[@]}"; do
    [[ "$c" == "lab-sudo-c" || "$c" == "lab-sudo-c2" ]] && sudo_req="true" || sudo_req="false"
    data=$(prepare_source "1.1.0" "$c")
    create_cask "$c" "1.1.0" "$sudo_req" "$data"
  done

  echo "✅ Lab Ready. Run 'brew outdated' to verify or open BrewMenu App."
}

finish() {
  echo "🧹 Cleaning Up Lab Environment..."

  # Check if tap exists
  if [ ! -d "$TAP_PATH" ]; then
    echo "Error: Local tap not found, maybe execute start first?"
    exit 1
  fi

  # Cleanup formulae and casks
  for f in "${FORMULAE[@]}"; do
    $BREW_BIN uninstall -q --formula "$f" 2>/dev/null || true
    rm -f "$FORMULA_DIR/$f.rb"
  done
  for c in "${CASKS[@]}"; do
    $BREW_BIN uninstall -q --cask "$c" 2>/dev/null || true
    rm -f "$CASK_DIR/$c.rb"
  done

  # Cleanup sudo log files
  sudo rm -f /Library/Logs/brew_lab_sudo_*.log

  # Aggressively remove residual directories in Caskroom and Cellar
  # (This handles the .upgrading ghost folders)
  for f in "${FORMULAE[@]}"; do
    sudo rm -rf "$(/opt/homebrew/bin/brew --prefix)/Cellar/$f" 2>/dev/null || true
  done
  for c in "${CASKS[@]}"; do
    sudo rm -rf "$(/opt/homebrew/bin/brew --prefix)/Caskroom/$c" 2>/dev/null || true
  done

  # Cleanup artifact targets in /tmp
  rm -f /tmp/brew_lab_lab-*
  rm -rf /tmp/brew_lab_payload_*

  # Cleanup tap
  $BREW_BIN untap $TAP_NAME

  echo "Done."
}

case "$1" in
start) start ;;
finish) finish ;;
status) status ;;
*) echo "Usage: $0 {start|finish|status}" ;;
esac
