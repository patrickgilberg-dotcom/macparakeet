#!/usr/bin/env bash
set -euo pipefail

# Meeting mixing and final transcription need FFmpeg even when all speech
# recognition runs locally. Bundle it so Finder launches never depend on PATH.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DESTINATION="${1:?Supply the generated bundle Resources/ffmpeg path}"
SOURCE="${FFMPEG_PATH:-${MACPARAKEET_FFMPEG_PATH:-}}"
if [[ -z "$SOURCE" ]]; then
  for candidate in \
    "/Applications/MacParakeet.app/Contents/Resources/ffmpeg" \
    "$HOME/Applications/MacParakeet.app/Contents/Resources/ffmpeg"; do
    if [[ -x "$candidate" ]]; then SOURCE="$candidate"; break; fi
  done
fi

if [[ -z "$SOURCE" ]]; then
  echo "No portable FFmpeg helper is available. Set FFMPEG_PATH to a portable Apple Silicon binary before building the app." >&2
  exit 1
fi
[[ -x "$SOURCE" ]] || { echo "FFmpeg source is not executable: $SOURCE" >&2; exit 1; }
mkdir -p "$(dirname "$DESTINATION")"
install -m 0755 "$SOURCE" "$DESTINATION"
if ! lipo "$DESTINATION" -verify_arch arm64; then
  echo "Bundled FFmpeg does not contain Apple Silicon support." >&2; exit 1
fi
NON_PORTABLE="$(otool -L "$DESTINATION" | awk 'NR > 1 {print $1}' | \
  awk '$0 !~ /^\/System\/Library\// && $0 !~ /^\/usr\/lib\// {print}')"
[[ -z "$NON_PORTABLE" ]] || {
  echo "FFmpeg requires non-system libraries; supply a portable static build." >&2
  printf '%s\n' "$NON_PORTABLE" >&2; exit 1;
}
"$DESTINATION" -version >/dev/null
VERSION_LINE="$("$DESTINATION" -version | head -n 1)"
DIGEST="$(shasum -a 256 "$DESTINATION" | awk '{print $1}')"
echo "Bundled required portable FFmpeg (source: $SOURCE)."
echo "  $VERSION_LINE"
echo "  sha256: $DIGEST"
