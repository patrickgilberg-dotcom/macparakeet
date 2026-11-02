#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../live_signing.sh"

# Public signing metadata fixtures only; never read or change the real Keychain.
security() { printf '%s\n' "$TEST_IDENTITIES"; }
codesign() { printf '%s\n' "$TEST_SIGNATURE" >&2; }
TEST_IDENTITIES='     0 valid identities found'
unset MACPARAKEET_CODESIGN_IDENTITY MACPARAKEET_ALLOW_ADHOC
[[ "$(macparakeet_pick_codesign_identity)" == - ]]
if macparakeet_require_live_build_identity - Live 2>/dev/null; then
  echo 'Live build accepted an implicit ad-hoc identity.' >&2; exit 1
fi
macparakeet_require_live_build_identity - Dev
MACPARAKEET_ALLOW_ADHOC=1 macparakeet_require_live_build_identity - Live 2>/dev/null

TEST_IDENTITIES='  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Example Person (TESTTEAM)"'
[[ "$(macparakeet_pick_codesign_identity)" == 'Apple Development: Example Person (TESTTEAM)' ]]
[[ "$(MACPARAKEET_CODESIGN_IDENTITY='Apple Development: Example Person (TESTTEAM)' macparakeet_pick_codesign_identity)" == 'Apple Development: Example Person (TESTTEAM)' ]]
[[ "$(MACPARAKEET_CODESIGN_IDENTITY=0123456789abcdef0123456789abcdef01234567 macparakeet_pick_codesign_identity)" == 0123456789abcdef0123456789abcdef01234567 ]]
if MACPARAKEET_CODESIGN_IDENTITY='Missing identity' macparakeet_pick_codesign_identity >/dev/null 2>&1; then
  echo 'Build accepted an unavailable explicit identity.' >&2; exit 1
fi

TEST_SIGNATURE=$'Signature=adhoc\nTeamIdentifier=not set'
if macparakeet_require_persistent_live_bundle /mock/Live.app 2>/dev/null; then
  echo 'Installer accepted an implicit ad-hoc bundle.' >&2; exit 1
fi
MACPARAKEET_ALLOW_ADHOC=1 macparakeet_require_persistent_live_bundle /mock/Live.app 2>/dev/null
TEST_SIGNATURE=$'Authority=Apple Development: Example Person (TESTTEAM)\nSignature size=4821'
macparakeet_require_persistent_live_bundle /mock/Live.app
echo 'Live signing policy tests passed.'
