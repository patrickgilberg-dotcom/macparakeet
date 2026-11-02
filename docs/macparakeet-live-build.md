# Building the personal Live fork

Live builds require a valid persistent local code-signing identity. The build
stops before compilation if none is available; the installer also rejects
ad-hoc Live bundles by default. This prevents a rebuild from silently changing
the identity macOS associates with recording permissions.

For local use, sign in to your Apple Account in **Xcode → Settings → Accounts**,
select your **Personal Team**, open **Manage Certificates**, and create an
**Apple Development** certificate. This uses the free Personal Team path;
paid Apple Developer Program enrollment is not required for this local build.
The private key stays in your local Keychain. The builder automatically selects
a valid Apple Development identity, then Mac Development or Developer ID. Use
`MACPARAKEET_CODESIGN_IDENTITY` to select an exact valid identity name or SHA-1
fingerprint explicitly. See Apple's [Personal Team guidance](https://developer.apple.com/help/account/basics/about-your-developer-account)
and [certificate management instructions](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates).

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

Finish changes, sign the final build, and install it at its final location
before granting macOS permissions. Keep the same persistent signing identity
for later builds. If an enabled System Settings switch disagrees with the app,
check the installed path and signing identity before asking for permission
again. Repeatedly reopening settings or flipping the same switch does not
repair an identity mismatch. The build and installer never modify TCC records.

For intentional throwaway QA only, set `MACPARAKEET_ALLOW_ADHOC=1` explicitly
for both building and installation. Set `MACPARAKEET_CODESIGN_IDENTITY=-` when
you deliberately want ad-hoc signing even though a certificate is available.
That mode warns that permissions may be lost on rebuilding. The ordinary Dev
workflow still permits ad-hoc builds; it is not the installed Live workflow.

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
