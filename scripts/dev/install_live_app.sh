#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
CONFIG="${MACPARAKEET_CONFIG:-Release}"
source "$SCRIPT_DIR/live_bundle_paths.sh"
SOURCE_APP="${1:-$(macparakeet_live_bundle_path "$ROOT_DIR" "$CONFIG")}"
DESTINATION_DIR="${MACPARAKEET_INSTALL_DIR:-$HOME/Applications}"
DESTINATION_APP="$DESTINATION_DIR/MacParakeet Live.app"
EXPECTED_ID="com.patrickgilberg.macparakeet-live"

require_live_bundle() {
  local actual
  actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")"
  [[ "$actual" == "$EXPECTED_ID" ]] || { echo "Refusing non-Live bundle: $1" >&2; exit 1; }
}

require_live_bundle "$SOURCE_APP"
source "$SCRIPT_DIR/live_signing.sh"
macparakeet_require_persistent_live_bundle "$SOURCE_APP"
# File-provider metadata may reappear on generated bundles in Documents after
# signing. Removing only these signing-invalid attributes preserves content.
xattr -dr com.apple.FinderInfo "$SOURCE_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$SOURCE_APP" 2>/dev/null || true
# Verify the complete copied signature below, outside file-provider folders.
# Finder metadata can be synthesized again immediately inside Documents.
[[ "$DESTINATION_DIR" == /* ]] || { echo "Installation directory must be absolute." >&2; exit 1; }
[[ ! -L "$DESTINATION_DIR" && ! -L "$DESTINATION_APP" ]] || { echo "Refusing a symlink installation target." >&2; exit 1; }
[[ "$SOURCE_APP" != "$DESTINATION_APP" ]] || { echo "Source and destination must differ." >&2; exit 1; }
mkdir -p "$DESTINATION_DIR"
if [[ -e "$DESTINATION_APP" ]]; then
  require_live_bundle "$DESTINATION_APP"
fi
INSTALLED_EXECUTABLE="MacParakeet"
if [[ -f "$DESTINATION_APP/Contents/Info.plist" ]]; then
  INSTALLED_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DESTINATION_APP/Contents/Info.plist")"
fi
[[ -n "$INSTALLED_EXECUTABLE" && "$INSTALLED_EXECUTABLE" != */* ]] || { echo "Invalid installed executable name." >&2; exit 1; }
source "$SCRIPT_DIR/stop_app_processes.sh"
stop_app_processes 10 "$DESTINATION_DIR" "$DESTINATION_APP/Contents/MacOS/$INSTALLED_EXECUTABLE"

# Copy completely before replacing a prior Live build; never touch MacParakeet.app.
STAGING_DIR="$(mktemp -d "$DESTINATION_DIR/.macparakeet-live-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$SOURCE_APP" "$STAGING_DIR/MacParakeet Live.app"
xattr -dr com.apple.FinderInfo "$STAGING_DIR/MacParakeet Live.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$STAGING_DIR/MacParakeet Live.app" 2>/dev/null || true
codesign --verify --deep --strict "$STAGING_DIR/MacParakeet Live.app"
macparakeet_require_persistent_live_bundle "$STAGING_DIR/MacParakeet Live.app"
if [[ -e "$DESTINATION_APP" ]]; then
  mv "$DESTINATION_APP" "$STAGING_DIR/Previous.app"
fi
if ! mv "$STAGING_DIR/MacParakeet Live.app" "$DESTINATION_APP"; then
  [[ ! -e "$STAGING_DIR/Previous.app" ]] || mv "$STAGING_DIR/Previous.app" "$DESTINATION_APP"
  exit 1
fi
echo "Installed: $DESTINATION_APP"
echo "Launch: open '$DESTINATION_APP'"
