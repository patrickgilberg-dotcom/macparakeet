# MacParakeet Live qualification

Qualification date: October 28, 2026 (America/Edmonton).

Installed production source: `d8d6477875b5`, branch `feat/macparakeet-live`,
[personal fork review](https://github.com/patrickgilberg-dotcom/macparakeet/pull/1).
Capture and provider reports identify their measured revisions separately. The
latest native replay and optimized WebSocket run used `d8d6477875b5`. Earlier
recordings and experiments retain their original source labels. The final update
adds a ten-second idle reuse bound; only completed responses refresh that activity.

## Installed build

- App: `/Users/patrickgilberg/Applications/MacParakeet Live.app`.
- Qualified local source: `/Users/patrickgilberg/Library/Caches/MacParakeet-Live/Source`.
  This resident clone avoids stalled iCloud/FileProvider reads in the original
  Documents checkout, which was preserved. Committed source is also pushed to the fork.
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
A socket already known to URLSession as closed is retired before the next send.
The initial state-only guard was insufficient: a real 180-second unused-warm-up
check failed before text with “Socket is not connected” in 51 ms. That failure
report is retained. Eligible recent sockets receive a bounded pre-send ping;
sockets idle for at least ten seconds retire before that check. A failed control
check can replace the socket before model input is sent. Cancellation or
account invalidation aborts instead. A connection can still fail after the ping,
and a sent model request is never replayed. A later real 180-second idle check
exposed repeated native pong callbacks during cancellation, which trapped a plain
checked continuation. That separate failure is retained. The callback now settles
through a mutex-protected exactly-once gate; late callbacks cannot resume it again.
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
  The installed `a4a73f90205a` app completed its own synthetic inference test:
  displayed first text 1,801 ms and first punctuation-delimited sentence 2,043 ms.
  This is one provider/UI test, not a hotkey-to-display result or a percentile.
  Its permissions remained all granted, and the saved Luna/none pair survived
  native settings navigation and reload.
- The CLI-created Keychain record initially denied the separate installed app.
  An explicit unlock action now exposes that state and requests macOS approval;
  the saved grant was preserved. Account/session resume after app restart worked.
- Live Ask has no API-key or paid fallback. Optional upstream provider routes
  remain separate and were left unconfigured.

The saved model was also checked independently of benchmark arguments. An observed
Sol/provider-default preference was restored through a completed Luna/none
benchmark run, and the persisted pair was read back. Settings now persists model
changes only from explicit Picker edits; a view reload cannot overwrite a newer
benchmark choice. The prior reload race was possible, but the cause of the observed
preference change was not proven.

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
- The final idle-socket health check passed **36 focused transport tests**, zero failures,
  including half-open replacement, ping timeout, cancellation/account invalidation
  during ping, deadline retirement, no inference replay and repeated/concurrent
  native callback settlement, idle expiry, successful-activity refresh and account
  invalidation during replacement. Both the supported
  Xcode Release app build and optimized benchmark build completed successfully.
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

## Signed-app recording and notes

On October 28 the signed `02c58b29d9dc` Release app completed a normal 100.788-second
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

The later `514fd8385e51` app also completed two user-stopped recordings: a
31.577-second microphone-and-system recording (100%/99.644% source coverage) and
a 38.620-second system-only recording (100% selected-source coverage). Both
finalized normally and reported healthy capture. All five selected raw/playback
files fully decoded with nonzero signal. The empty unselected microphone
placeholder in system-only mode is expected. These artifact checks do not establish
lexical recognition accuracy or a successful live answer. Incidental call speech
was not inspected or included in the content-free report.

Through the `d8d6477875b5` update, the installed app retained the same certificate-based
designated requirement, protected ChatGPT connection and granted permissions.
Capture defaults were restored to microphone plus system audio, with Start meetings
muted off. Recording and playback tests paused at the user's quiet-first request. They
resumed only after the user explicitly approved audio again. The user confirmed
that they intentionally stopped the earlier recordings.

## Native speech and global shortcut qualification

The installed `a4a73f90205a` app completed a 668.331-second dual-source recording
containing two approved generated questions and time for the user to try the UI.
Capture finalized healthy: microphone coverage 100%, system coverage 99.9847%,
no interruptions and no remaining recording lock. All three selected audio files
fully decoded with nonzero signal. Saved artifacts were nonempty; a read-only
aggregate found one conversation with five user/assistant pairs. Incidental audio,
transcript content and the user's custom-question wording were not exported.

All five live requests completed. They included a focused physical shortcut press,
automated Help button, user-entered custom question, and two accepted native Carbon
global callbacks. The user confirmed pressing from Codex; no Live UI inspection
intervened before the global callbacks at 23:15:50.113Z and 23:16:11.111Z. The
initial focused press alone was not used as global-delivery proof. The first
question produced a useful pilot-preparation reply; the changed unapproved-rollout
question correctly rejected a Monday commitment. The saved chat retained all five
pairs, including the custom-question route.

| Native stage, all five trials | Median | Nearest-rank p95 |
| --- | --- | --- |
| Invocation to request | 0.424 s | 0.526 s |
| Request to text | 3.663 s | 5.150 s |
| Invocation to text | 4.087 s | 5.471 s |
| Invocation to sentence | 4.165 s | 5.559 s |
| Invocation to completion | 4.204 s | 5.622 s |

Contexts, triggers and spacing differed; with five samples p95 is the maximum.
These live results did not meet the one-/two-second targets, despite faster
continuous warm-provider trials. The two global callbacks reached a sentence in
2.409 and 5.309 seconds. The provider/connection stage dominated the slower cases.
Source inspection confirmed that Live's direct stream route retains the saved
reasoning setting; the explicit-model abstraction branch is not used here.

For the second spoken fixture, the harness requested Help in the same automation
invocation as observed playback completion. Playback-end proxy to invocation was
approximately 0.276 s; proxy to text/sentence was 4.363/4.441 s. The first fixture
had about 7.012 s of human/tool delay before invocation, which is reported separately
rather than attributed to the pipeline. These are actual captured playback tests,
not an independent acoustic speech-end measurement. The full content-free report
retains all five trials and their raw clocks.

### Final connection-policy replay (`d8d6477875b5`)

The client now retires a socket after ten seconds without a completed response,
using creation time for an unused warm-up. This avoids waiting up to two seconds
for a health check after a human pause. Rapid follow-ups still reuse the socket;
token expiry and the fixed 55-minute age limit remain unchanged. This is a client
latency policy, not a measurement of the server's idle timeout.

The matched requested three-minute unused-warmup check completed once with text
in 1.634 s, a sentence in 1.722 s and completion in 1.971 s. Diagnostics confirmed
Luna/none/WebSocket and idle-expired replacement before send, with no ping wait.
The earlier callback-safe build's one post-idle sentence took 4.011 s. These are
single observations rather than a controlled speed distribution.

The final installed app captured another 323.177-second microphone-and-system
recording. Both sources completed healthy (100% microphone, 99.9081% system
coverage), all three audio files fully decoded, artifacts were nonempty and no
recording locks remained. Saved chat had four user and three assistant messages;
the cancelled request is not represented as a completed answer. The fresh-launch
recording initialization took about 25 seconds before first capture buffers in
this observation; playback waited for readiness. This startup time is separate
from per-question timing.

The automated spoken replay correctly refused the unapproved Monday commitment.
Playback-end proxy to invocation/text/sentence was approximately 0.480/2.859/2.960 s;
invocation to sentence was 2.480 s, including 0.646 s before request and 1.734 s
request-to-text. Its context/history differed from the earlier button trial, so
the observed 4.441-to-2.960-second proxy change is not a controlled causal estimate.

A custom request cancelled before visible text; a subsequent request completed
on a fresh socket. An immediate follow-up reused the connection with a 64 ms pong
and reached text/sentence in 1.393/1.509 s from invocation. Recovery on the fresh
socket took 4.140 s to a sentence, preserving the slower result. All four outcomes
are retained: three completed and one cancelled. Across only the three completions,
invocation-to-text median/p95 was 2.380/3.455 s; sentence 2.480/4.140 s; completion
2.508/4.190 s. These mixed contexts and connection states are exploratory, not a
service guarantee. Diagnostics confirm Luna/none/WebSocket for every request.
The registered-hotkey implementation is unchanged from the two verified global
callbacks above. The installed app retains all three granted permissions and is
left open in Library, with no recording or test helper running.

## Timing evidence and limits

Initial measurements are preserved under `benchmarks/chatgpt-live/results/`.
They used the earlier, less constrained opening-sentence prompt and shorter
long-context fixture, so they are a baseline rather than final-build guarantees.
The first subscription inference took 3,215 ms to text and 4,319 ms to the first
sentence; it followed authorization and model discovery and is not a clean
network/DNS cold-start measurement.

A later comparison discovered all eight account-visible models and tested their
lowest accepted reasoning setting. Across 59 Responses attempts, 55 completed and
four rejected unsupported-effort probes were retained; no accepted request failed.
The benchmark choice is **GPT-6 Luna with `none` reasoning**. In five repeated trials
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

The latest optimized Release WebSocket run measured installed production source
`d8d6477875b5`, including the final idle policy and exactly-once native callback
settlement. All **11 of 11** responses completed with nonempty text. The explicit
HTTP/SSE control on `ef90261f206f` also completed **11 of 11**; its code path was
unchanged by the later WebSocket-only changes. Both use GPT-6 Luna / `none`, the
same prompt and bounded context. No compiler, audio-decode test or other synthetic
inference ran during either speed comparison.

| Transport (measured source) | Context | First text median / p95 | First sentence median / p95 |
| --- | --- | --- | --- |
| WebSocket (`d8d64778`) | Recent | 1.509 / 2.714 s | 1.595 / 2.803 s |
| WebSocket (`d8d64778`) | Bounded long meeting | 1.248 / 1.462 s | 1.420 / 1.708 s |
| HTTP/SSE (`ef90261f`) | Recent | 1.724 / 2.254 s | 1.874 / 2.473 s |
| HTTP/SSE (`ef90261f`) | Bounded long meeting | 1.493 / 1.692 s | 1.820 / 1.935 s |

Each warm row has five trials; nearest-rank p95 is therefore the slowest sample.
WebSocket had lower medians in both contexts and lower long-context p95; HTTP
had lower recent-context p95 in this comparison. Sequential, unrandomized runs and
repeated identical fixtures may benefit from provider caching and do not establish
an unconditional transport-speed advantage.

The separate first-process WebSocket trial took 1.813 s to text and 2.011 s to a
sentence, including a fresh socket handshake. The HTTP control took 1.553/1.641 s,
after model discovery had warmed its HTTP pool. These are not untouched network,
DNS or operating-system cold starts. An earlier Release socket first-process
sentence took 4.217 s; that historical result is retained rather than replaced
with the faster sample. Latest WebSocket openings were 11–14 words, with no opening semicolons or
greetings. No approval was fabricated, and exports stayed conditional. Two outputs
phrased the security-review gate less explicitly, so universal explicit approval
wording is not claimed.

Historical `a4a73f90205a` qualification repeated the failing unused-warmup scenario
after the callback fix. Both its Debug protocol check and optimized Release check
completed their single synthetic
request after 180 unused seconds without a trap or replay. Debug ran alongside
builds and is excluded from speed claims. The optimized post-idle trial took
3.921 s to text, 4.011 s to a sentence and 4.215 s to completion. This is a single
post-idle result, not a warm percentile; it does not prove that the original socket
remained connected. That historical a4 native app separately completed its quiet
Settings test (1,801/2,043 ms text/sentence), retained all permissions and preserved
Luna/none through reloads. The d8 post-idle and native replay results are reported
separately above.

Native global shortcut delivery, custom questions, changed-question relevance,
normal recording finalization and saved chat are verified in the revisions above.
Exact acoustic speech-end timing and physical display scan-out were not measured;
playback-end proxies and view-model publication clocks are identified as such.
No paid developer membership, self-signed root, weakened code requirement or TCC
database change is used. The small samples do not establish consistent one-second
visible-text or two-second speech-to-useful-sentence guarantees.

Official transport references: [SIWC preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations),
[Responses WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode).

Apple references: [ad-hoc rebuild permission behavior](https://developer.apple.com/forums/thread/819406),
[code requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[free Personal Team setup](https://developer.apple.com/help/account/basics/about-your-developer-account),
[unrestricted Mac signing without a provisioning profile](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).
