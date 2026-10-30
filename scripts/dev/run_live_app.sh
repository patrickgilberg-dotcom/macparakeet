#!/usr/bin/env bash
set -euo pipefail

# Supported Xcode/macro/signing workflow, optimized by default for timing runs.
export MACPARAKEET_APP_FLAVOR=Live
export MACPARAKEET_CONFIG="${MACPARAKEET_CONFIG:-Release}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$SCRIPT_DIR/run_app.sh" "$@"
