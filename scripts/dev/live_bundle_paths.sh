#!/usr/bin/env bash

# Shared by the builder and installer. Keep signed bundles out of Documents:
# FileProvider may synthesize FinderInfo again immediately after it is removed.
macparakeet_live_build_root() {
  local checkout_root="$1"
  local checkout_hash
  [[ "$checkout_root" == /* ]] || { echo "Checkout root must be absolute." >&2; return 1; }
  checkout_hash="$(printf '%s' "$checkout_root" | shasum -a 256)"
  checkout_hash="${checkout_hash%% *}"
  printf '%s/Library/Caches/MacParakeet-Live/Builds/%s\n' "$HOME" "$checkout_hash"
}

macparakeet_live_bundle_path() {
  local checkout_root="$1"
  local configuration="$2"
  case "$configuration" in
    Debug|Release) ;;
    *) echo "Build configuration must be Debug or Release." >&2; return 1 ;;
  esac
  printf '%s/%s/MacParakeet Live.app\n' "$(macparakeet_live_build_root "$checkout_root")" "$configuration"
}
