#!/usr/bin/env bash

macparakeet_pick_codesign_identity() {
  local preferred="${MACPARAKEET_CODESIGN_IDENTITY:-}"
  local identities identity family
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ "$preferred" == - ]]; then printf '%s\n' -; return; fi
  if [[ -n "$preferred" ]]; then
    if grep -Fq "\"$preferred\"" <<<"$identities" || {
      [[ "$preferred" =~ ^[[:xdigit:]]{40}$ ]] && grep -Fiq "$preferred" <<<"$identities"
    }; then
      printf '%s\n' "$preferred"
      return
    fi
    echo "The requested signing identity is not a valid local code-signing identity. Check Xcode Accounts → Manage Certificates." >&2
    return 1
  fi
  for family in "Apple Development" "Mac Development" "Developer ID Application"; do
    identity="$(sed -n "s/.*\"\($family:.*\)\".*/\1/p" <<<"$identities" | head -n 1)"
    if [[ -n "$identity" ]]; then printf '%s\n' "$identity"; return; fi
  done
  printf '%s\n' -
}

macparakeet_require_live_build_identity() {
  local identity="$1"
  local flavor="$2"
  [[ "$flavor" == Live && "$identity" == - ]] || return 0
  if [[ "${MACPARAKEET_ALLOW_ADHOC:-0}" == 1 ]]; then
    echo "Warning: intentional ad-hoc Live QA build; rebuilding changes its macOS permission identity." >&2
    return 0
  fi
  echo "MacParakeet Live needs a persistent local signing identity before building. In Xcode Settings → Accounts, select your free Personal Team, open Manage Certificates, and create Apple Development. Paid enrollment is not required for this local build. See docs/macparakeet-live-build.md." >&2
  echo "For intentional throwaway QA only, explicitly set MACPARAKEET_ALLOW_ADHOC=1." >&2
  return 1
}

macparakeet_require_persistent_live_bundle() {
  local bundle="$1"
  local details
  if ! details="$(codesign -dv --verbose=4 "$bundle" 2>&1)"; then
    echo "The Live source bundle has no readable code signature." >&2
    return 1
  fi
  if grep -Fq 'Signature=adhoc' <<<"$details" || ! grep -q '^Authority=' <<<"$details"; then
    if [[ "${MACPARAKEET_ALLOW_ADHOC:-0}" == 1 ]]; then
      echo "Warning: installing an intentional ad-hoc Live QA build; its permissions will not reliably survive rebuilding." >&2
      return 0
    fi
    echo "Refusing an ad-hoc MacParakeet Live installation. Rebuild using a persistent local signing identity. For intentional throwaway QA only, explicitly set MACPARAKEET_ALLOW_ADHOC=1." >&2
    return 1
  fi
}
