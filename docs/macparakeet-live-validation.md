# MacParakeet Live qualification

Qualification date: October 28, 2026 (America/Edmonton).

Production source: `d82cdce66e4d`, branch `feat/macparakeet-live`,
[personal fork review](https://github.com/patrickgilberg-dotcom/macparakeet/pull/1).
Installed Release build metadata: `02c58b29d9dc`. Later test-fixture, signing-workflow
and qualification-document commits leave the production Swift implementation unchanged.

## Installed build

- App: `/Users/patrickgilberg/Applications/MacParakeet Live.app`.
- Hardware: MacBook Air, Apple M5, 10 CPU cores, 16 GB memory.
- OS/toolchain: macOS 26.5.1, Apple Swift 6.3.3, Apple Silicon Xcode Release build.
- Build workflow: `scripts/dev/run_live_app.sh`, including the repository's macro
  validation flag and optimized Release configuration. Assembly/signing occurs
  outside synced Documents. Installer verifies the staged signature before replacement.
- The final installed build is signed with an Apple Development certificate from
  the free Personal Team, with Team Identifier `3G3BKNXU3A`. Its designated
  requirement uses the app identifier and Apple certificate chain instead of an
  exact code hash, providing a stable identity while the same certificate is used.
  Signing setup required Apple's WWDR G3 intermediate certificate, obtained from
  the [official Apple PKI source](https://www.apple.com/certificateauthority/).
- Earlier ad-hoc builds changed identity on rebuilding, causing recording grants
  to disagree with the enabled app name in Settings. Persistent signing resolves
  that build-identity blocker. Live builds and installation now require persistent
  signing by default; intentional throwaway QA requires `MACPARAKEET_ALLOW_ADHOC=1`.
- The obsolete Live Accessibility and Screen & System Audio entries were removed
  and the installed signed bundle added through System Settings. After restart,
  the installed app reports all three permissions granted. Original MacParakeet
  permission entries were left intact.
- Bundled FFmpeg 9.0.2 was copied read-only from the existing upstream app,
  checked for Apple Silicon/system-library-only dependencies, signed and smoke-tested.
- Installed bundle signature passes deep/strict verification. The original
  `/Applications/MacParakeet.app` executable still matches its pre-task SHA-256:
  `55e7a110c6c952fbeb876cd60e576a605d7a45af5f45b2bb205595769219fc70`.

## Reverse-engineered path

The existing capture service owns durable microphone/system audio independently
of preview transcription. `CaptureOrchestrator` handles pairing, conditioning
and chunking; `LiveChunkTranscriber` and `MeetingChunkResultBuffer` own ordered
preview results. Live Ask uses the existing `TranscriptChatViewModel` and panel.

The fork adds a freshness barrier before one direct model request: cross the
invocation's capture timestamp, drain admitted preview work, flush pending pairs
and short tails, wait for the relevant recognition jobs, and reject unresolved
preview loss. Pre-gap held audio cannot masquerade as new speech. Older gaps
remain disclosed after later speech recovers the current question. Durable audio
and final transcription remain independent.

`LiveAnswerContext` bounds recent text, extracts older anchors, retains compact
history and accepts local preparation/notes. Stable instructions stay separate
from quoted meeting data. `ChatGPTLiveClient` uses the app's own OAuth bearer
token with a persistent native URLSession WebSocket. One serialized default lane
sends full bounded input on each turn, with `store:false` and no previous-response
reference. Account, model, token or expiry changes retire the socket. Cancellation,
incomplete responses and errors close it; sent requests are never silently replayed.
Only a nonempty `response.completed` is terminal success. Explicit HTTP/SSE mode
remains available for comparisons (`store:false`, `stream:true`). Live requests
use neither a CLI nor tools. The opening sentence targets 8–12 words, at most 18,
followed by up to two supporting bullets; conditions take precedence over brevity.

Live's global answer shortcut now uses macOS registered hotkeys rather than a
keyboard event monitor. The old tap could be created while macOS removed its
key-down/up event mask, falsely suggesting availability. The replacement registers
Option-Command-Space exclusively; a conflict selects Control-Option-Command-Space,
with the actual chord shown in Ask. Registration failure is shown explicitly.

## Authentication and cloud verification

- The app's own browser registration, PKCE, loopback callback, RS256/JWKS identity
  validation and ChatGPT plan permission completed successfully.
- Completed streamed inference was verified, beyond login/model discovery.
- Account-specific discovery returned eight visible models. The initial comparison
  tested five shortlisted current models and retained rejected effort probes and failures.
- Native installed-app Settings shows the account and **Using ChatGPT plan**.
  Its own completed inference test measured 2,604 ms to text and 2,910 ms to the
  first punctuation-delimited sentence. These are provider measurements, not a
  hotkey-to-display result.
- The CLI-created Keychain record initially denied the separate installed app.
  An explicit unlock action now exposes that state and requests macOS approval;
  the saved grant was preserved. Account/session resume after app restart worked.
- Live Ask has no API-key or paid fallback. Optional upstream provider routes
  remain separate and were left unconfigured.

## Automated verification

- Earlier affected-area focused run: **367 tests passed**, zero failures.
- Final integrated transport/hotkey run: **194 tests passed**, zero failures.
  It includes real-module authentication/session, SSE, WebSocket, hotkey, live
  answer, transcript-chat publication and meeting-flow coverage. New socket tests
  use injected fixtures and never access real credentials or the network.
- Authentication/session qualification includes 25 tests covering PKCE,
  callback validation, signature/claims, reduced/revoked scopes, atomic rotating
  refresh checkpoints, temporary failures, concurrent refresh across two actors,
  revocation and explicit blocked-Keychain recovery. Tests use synthetic credentials.
- Changed Swift files pass strict formatting lint. Build/install/helper scripts
  pass shell syntax checks.
- The broad run exercised **8,273 XCTest tests**, with 35 skipped, plus 30 Swift
  Testing tests. It found five failed assertions in four outdated test fixtures:
  one expected the old optional Ask provider and three expected upstream export
  folders. These fixtures were updated for the direct simulated stream and Live
  directories. All **49 meeting-flow tests** and **175 matching settings tests**
  then passed. The later WebSocket/registered-hotkey changes are covered by the
  final focused run rather than a second broad run.
- The complete broad suite was not repeated, following the repository's explicit
  once-per-task limit. The corrected areas were rerun with focused filters.
- Independent security, concurrency, freshness, data-preservation and build
  reviews converged after the reported issues were fixed. Local no-mistakes and
  Greptile executables were unavailable. The fork reports no hosted CI checks.

## Recorded-audio verification

An actual installed-app microphone-and-system recording captured generated spoken
audio, including acoustic speaker-to-microphone pickup. This is not an independent
human conversation or Bluetooth-device qualification.

- Raw microphone/system sources both contain decodable audio. Reported source
  coverage: microphone 100%, system 98.9%; both source capture statuses complete.
- Missing FFmpeg initially prevented playback mixing/final transcription. The
  raw recordings survived. After helper packaging was fixed, the installed app
  recovered the existing recording and produced playback, transcript, Markdown
  and manifest artifacts. `recording.lock` was settled.
- The saved transcript is completed/recovered with Parakeet. On the controlled
  32-word fixture it contained one extra word in the product name (3.125% fixture
  WER); the final question and its facts matched. This small fixture is not an
  accuracy estimate for general meetings.
- Recording folder:
  `/Users/patrickgilberg/Library/Application Support/MacParakeet-Live/meeting-recordings/AD415CCE-7257-414F-A3F7-6B105C7525BD`.

## Final signed-app recording and notes

On October 28 the installed signed Release app completed a normal 100.788-second
microphone-and-system recording. Both raw sources and mixed playback fully decoded
with nonzero signal. Capture reports healthy/complete sources with microphone
100% and system 99.90% coverage; no interrupted source or remaining recording lock.
The 25 normalized words of the generated system-audio fixture matched contiguously,
including the final word Tangerine. Incidental microphone audio was not used to
claim recognition accuracy or copied into qualification reports.

Normal capture shutdown and playback mixing took 629 ms; this excludes the queued
final transcription. The completed meeting opened in Library with playback and
transcript. A synthetic note showed Saved, survived navigating away and reopening,
and matched the database, transcript artifact and `notes.md`.

Standard preview windows remain unchanged: fixed 5-second windows with 1-second
overlap, or VAD-guided 2–10-second windows. Explicit Ask flushes the pending tail.
A 30-second recording interval sampled process resources every two seconds:
CPU median/p95 9.3%/18.0%; RSS median/p95 120.10/131.98 MiB. This interval followed
the generated audio burst. These are 16 OS-smoothed CPU/RSS samples, not a battery,
long-meeting or complete GPU/ANE memory measurement. Idle baseline was 0.1% CPU
and 46.08 MiB RSS. Content-free capture and resource evidence is committed under
`benchmarks/chatgpt-live/results/`; recordings and incidental speech stay local.

## Timing evidence and remaining qualification

Initial measurements are preserved under `benchmarks/chatgpt-live/results/`.
They used the earlier, less constrained opening-sentence prompt and shorter
long-context fixture, so they are a baseline rather than final-build guarantees.
The first subscription inference took 3,215 ms to text and 4,319 ms to the first
sentence; it followed authorization and model discovery and is not a clean
network/DNS cold-start measurement.

A later comparison discovered all eight account-visible models and tested their
lowest accepted reasoning setting. Across 59 Responses attempts, 55 completed and
four rejected unsupported-effort probes were retained; no accepted request failed.
The selected model is **GPT-6 Luna with `none` reasoning**. In five repeated trials
per context, HTTP first-sentence median/p95 was 1.752/2.557 seconds for recent
context and 1.610/3.262 seconds for the actual bounded long-meeting fixture.

The isolated WebSocket comparison completed all ten socket and ten paired HTTP
responses. Warm socket sentence median/p95 was 1.123/2.715 seconds for recent
context (four samples) and 1.160/1.547 seconds for long context (five samples).
The first socket request, including handshake, took 2.086 seconds to a sentence.
These are provider-only timings. The socket always preceded paired HTTP, and small
samples/cache/order effects limit causal claims. All outputs retained security and
approval conditions, but most openings exceeded the original 18-word instruction.
The production prompt was tightened without mechanically truncating conditions.
Final production transport verification is reported separately below.
A native protocol check found HTTP 400 responses when sending the optional
`stream_id` field with this account's subscription route. Omitting it restored
successful default-lane responses. The production client therefore uses the proven
serialized default lane. These Debug protocol checks are excluded from speed claims.

Three completed installed-app HTTP button/custom-question trials had invocation-to-
sentence median/p95 2.549/2.780 seconds, including transcript preparation (median
277 ms). A fourth response was cancelled before text; a new request then completed.
The second spoken question changed the answer from pilot preparation to rejecting
an unapproved rollout promise. The final question word was visible in the live
transcript. Notes and all seven chat messages persisted, and saved answers remained
visible in Library. These tests exposed the old global shortcut failure; they do
not qualify shortcut delivery. Playback-end proxies were dominated by tool round-trip
trigger gaps, so they cannot establish the speech-end latency target.

The final harness uses the actual Live context builder, a raw long-meeting fixture
that exceeds the context bound, letter/number-based first text, explicit failed
trials, hardware metadata, nearest-rank median/p95 and saved outputs. Sentence
timing is a punctuation proxy; usefulness requires inspecting the answer.

Pending at this report revision: signed Release qualification of the registered
hotkey and production WebSocket, final live timing,
and exact acoustic speech-end timing. The installed prior build's capture,
transcription, normal-stop artifacts, notes and saved chat passed. Both app and
benchmark Keychain grants now work. No paid developer membership, self-signed root,
weakened code requirement or TCC database change is used. Small benchmarks do not
establish consistent one-second text or two-second useful-sentence guarantees.

Official transport references: [SIWC preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations),
[Responses WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode).

Apple references: [ad-hoc rebuild permission behavior](https://developer.apple.com/forums/thread/819406),
[code requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[free Personal Team setup](https://developer.apple.com/help/account/basics/about-your-developer-account),
[unrestricted Mac signing without a provisioning profile](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).
