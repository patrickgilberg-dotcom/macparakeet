# MacParakeet Live isolation

This personal fork is a separate app. Its identity does not depend on Debug
versus Release or on environment variables supplied by a launcher.

| Surface | Live identity |
| --- | --- |
| App display name | MacParakeet Live |
| Bundle and shared preferences domain | `com.patrickgilberg.macparakeet-live` |
| Default Application Support root | `~/Library/Application Support/MacParakeet-Live` |
| Default logs | `~/Library/Logs/MacParakeet-Live` |
| Default document exports | `~/Documents/MacParakeet-Live` |
| Default temporary directory | `NSTemporaryDirectory()/macparakeet-live` |
| Meeting URL scheme | `macparakeet-live` |
| Credential service prefix | `com.patrickgilberg.macparakeet-live.` |

`LiveAppIdentity` is the shared source of identity for GUI, Core and the CLI.
`AppPaths` owns writable roots. An explicit absolute
`MACPARAKEET_DEBUG_APP_STATE_DIR` overrides runtime state for QA; an unlaunched
Dev bundle defaults to `MacParakeet-Live-Dev`. A Finder launch of the installed
Live bundle requires no environment variables for isolation.

The fork does not migrate or import upstream preferences, Keychain entries,
database, recordings, transcripts or speech models. Existing account keys keep
their names inside the new services. All speech-model downloads and deletion
target Live-owned storage; global FluidAudio cache deletion is forbidden.
Explicitly selected export destinations remain a user-controlled setting in
the Live preference domain.

Upstream Sparkle updates are disabled at startup, omitted from menus, disabled
in Settings, and rejected by the updater delegate regardless of app version.
Live bundles contain no upstream appcast URL. GPL and third-party notices ship
inside the bundle.

Build using `scripts/dev/run_live_app.sh` (Release by default). Set
`MACPARAKEET_BUILD_ONLY=1` to package and sign without launching. The wrapper
uses the supported Xcode workflow, including `-skipMacroValidation` and local
signing. Live builds require a persistent valid local signing identity before
compiling. The installer refuses ad-hoc Live signatures by default. Intentional
throwaway QA must explicitly set `MACPARAKEET_ALLOW_ADHOC=1`; ordinary Dev
builds retain their ad-hoc fallback. No signing helper edits TCC permissions.
`scripts/dev/install_live_app.sh` validates the Live bundle identity
and signature, quits only the exact installed Live executable before replacing
it, and installs under `~/Applications` by default. Override
`MACPARAKEET_INSTALL_DIR=/Applications` when that directory is writable. It
never replaces an app named `MacParakeet.app`.

Live bundles are assembled and signed in the per-checkout cache
`~/Library/Caches/MacParakeet-Live/Builds/<checkout-path-sha256>/<configuration>/`,
outside Documents and its FileProvider metadata handling. Intermediate Xcode
products remain in the checkout. Builder and installer share the same path
resolver; the ordinary-quit guard separately owns the raw checkout executable
and the exact replaced cache-bundle executable.

The distribution builder also defaults to the Live identity and rejects other
names and bundle identifiers before modifying an artifact. It registers only
the Live meeting scheme, disables automatic checks, omits update feed and
signing-key metadata, and verifies those keys remain absent in the bundle.

Focused tests: `AppPathsTests`, `LiveAppIsolationTests`, `ModelDeletionTests`,
and `SparkleUpdateGuardTests`. Build and installed-bundle validation remain
necessary in addition to unit tests.
