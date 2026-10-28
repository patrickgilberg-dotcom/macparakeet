# Building the personal Live fork

Build an optimized local signed app without launching:

```bash
MACPARAKEET_BUILD_ONLY=1 scripts/dev/run_live_app.sh
```

Xcode's intermediate products remain in `.build/xcode-live`. The generated
app is assembled and signed outside Documents under
`~/Library/Caches/MacParakeet-Live/Builds/<checkout-path-sha256>/<configuration>/MacParakeet Live.app`.
This prevents FileProvider from reattaching metadata while codesigning. The
builder and installer resolve this per-checkout path through the same helper.
The builder prints its exact bundle path.

Install the verified Live app under the current user's Applications folder:

```bash
scripts/dev/install_live_app.sh
open "$HOME/Applications/MacParakeet Live.app"
```

Use `MACPARAKEET_INSTALL_DIR=/Applications` with the installer when that
directory is writable. The original `/Applications/MacParakeet.app` is never
the installation target. Launching by Finder also uses isolated Live storage.
Rebuilds must first quit their exact replaced executable; the inherited
shutdown helper preserves unrelated upstream instances and active-recording
quit confirmation.

The build retains the original icon, GPL license and third-party notices.
It also bundles and smoke-checks a portable Apple Silicon FFmpeg binary,
required for meeting mixing and final transcription. `FFMPEG_PATH` can select
a binary explicitly. Otherwise it copies an existing upstream installation's
helper without modifying that installation. Its version and checksum are
printed in the build report. Installed Finder launches never depend on a
shell's executable search path.
Upstream auto-updates are disabled. Install future builds from this fork.
See [the isolation contract](../spec/contracts/live-app-isolation.md) for the
preference, credential and data locations.
