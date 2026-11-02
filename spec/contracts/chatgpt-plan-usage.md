# ChatGPT plan usage in MacParakeet Live

This locally running personal GPL fork owns its authorization. It does not use
Codex credentials, ChatGPT browser cookies, Servant, an API key, a per-question
CLI process, or a paid fallback. Optional upstream AI providers remain separate
from the Live Ask path.

## Authorization and storage

`ChatGPTAuth` starts a listener bound to `127.0.0.1` before opening the system
browser. First registration uses `dynamic_agent_client`, the consistent actual
app name and a persisted opaque UUID host ID. Later sign-in reuses the issued
client ID. Each attempt has independent cryptographic state, nonce and PKCE
S256. The exact callback path is `/auth/callback`. Host, port, method, state,
duplicates and returning-client substitutions are checked.

OpenID discovery and JWKS are restricted to the official HTTPS auth origin.
ID-token RS256 signature, issuer, audience, authorized party, expiry, issued-at,
subject and sign-in nonce are validated before activation. A reconnect must
match the saved subject. Granted token-response scopes determine plan access.
Denied consent and disabled plan use remain visible states.

Registrations and tokens are stored atomically in the Live-specific Keychain
service `com.patrickgilberg.macparakeet-live.chatgpt`. The persistent host ID and
refresh lock live under `MacParakeet-Live/ChatGPT`. A cross-process file lease
serializes rotating refreshes. A pending rotation is checkpointed before identity
validation; temporary key-service failures do not reuse an already-rotated token.
Terminal refresh errors invalidate credentials while retaining registration.
Disconnect attempts official refresh-token revocation before clearing tokens.
Unconfirmed remote revocation is reported. Sign-in cancellation invalidates the
attempt, including after callback and token exchange. No token or hinted
authorization URL belongs in logs, source control or benchmark reports.

## Inference

Automatic final minutes use a dedicated `ChatGPTLiveClient` instance through the
same authorized plan and pinned session validation. Its physical socket is
separate from foreground Live Ask; no named stream lane or new credential is
introduced. A weak process registry ensures account switches and disconnects
cancel requests on both foreground and background clients. See
[automatic minutes](live-meeting-minutes.md) for source scope and retry rules.

`ChatGPTLiveClient` implements the existing `LLMClientProtocol`. It uses a
persistent native URLSession directly with the OAuth bearer token. Model choices
come from the selected account's public `/v1/models` catalog (`models`, `slug`,
`display_name`, `visibility`), preserving server order. Model selections are
separate for each saved account registration. Active-account checks bind model
selection and credentials; switching or disconnecting cancels singleton streams.

The default native transport is a persistent WebSocket to
`wss://api.openai.com/v1/responses`. Each turn sends `response.create`,
`store:false`, the full bounded input history, and instructions. It omits
`stream`, `background`, tools, and `previous_response_id`. The explicit
`ChatGPTTransport.httpSSE` comparison mode uses HTTP POST with `stream:true`.
Unsupported sampling/token/storage fields are omitted in both modes. Reasoning
effort is sent only when explicitly selected by a successful capability
experiment; the catalog does not promise a reasoning-effort schema. Redirects
are refused. Content-free diagnostics record the resolved model/effort/transport,
fresh/reused/idle-expired/ping-replacement connection mode, and ping duration.
These records omit account IDs, tokens, URLs, prompts, transcripts and output. No transport automatically replays a failed or possibly accepted
request, and neither can switch to a different billing path.

The socket actor grants one exclusive FIFO request lease on the implicit default
lane. It omits optional `stream_id`: the signed native SIWC route rejected named
lanes with HTTP 400 while the otherwise equivalent unnamed control completed.
General Responses multiplexing documentation does not establish that optional
field's compatibility with this route. Each turn obtains current credentials after acquiring that lease. Reuse
requires the same account, model, access-token fingerprint, and live connection
generation, plus a native task that is still running with no close code. Cached
connections are also retired after 10 seconds without a completed response; an
unused warm-up socket uses its creation time. Only terminal success refreshes
this idle activity, while token expiry and the 55-minute hard age remain fixed.
Idle-expired sockets are replaced before pinging or sending model input. This
is a conservative client latency policy, not a claim about the server's idle timeout. A known
closed idle socket is retired before sending the next request, without replaying
a request against it. A cached socket also receives a WebSocket ping with a
two-second deadline before model input is sent. Native pong callbacks pass through
an exactly-once mutex-protected continuation gate; duplicate or late callbacks
from closing a socket cannot resume a completed Swift task again. If that control
check fails or
times out, the still-owned lease retires the old socket, rechecks authorization,
and opens one fresh socket before its single model request. Cancellation or an
invalidated account epoch prevents this replacement. A failure after sending
`response.create` is never retried or replayed. Token rotation, the conservative token-expiry reuse margin, or a
55-minute connection age causes a new handshake before the next request.
Cancellation, account change, deadline, incomplete output, and other failures
close the owned socket; old readers cannot deliver into a new lease. Cancelling
a queued request does not close another request's socket. Warmup opens only the
handshake and sends no meeting text or generated request.

The byte-level HTTP SSE decoder preserves blank-line boundaries, CR/LF and
split Unicode. The socket decoder checks created/completed response identity
and rejects a mismatched optional `response_id` on text deltas. It does not require
named-lane echoes. Both yield text deltas immediately and require `response.completed`
plus meaningful text for success. Usage limits, incomplete events, malformed
framing, interrupted connections and cancellation cannot mark a partial answer
complete. The UI marks failed partial answers incomplete.

During recording, local chat checkpoints preserve admitted questions and only
terminal-completed assistant turns. This is app-owned recovery state, not
ChatGPT account history. Local saving can fail independently of inference;
that failure remains visible and never causes a silent provider replay. Native
interruption recovery restores the stable conversation before settling the
recording lock and preserves any conversation the user already edited.

The spoken opening targets 8–12 words with an 18-word maximum, followed by at
most two supporting bullets. Accuracy and necessary conditions take priority;
output is never mechanically truncated to force a word count.

## Rolling meeting memory and cloud scope

The user explicitly authorized automatic cloud summaries every three minutes
while recording, alongside fresh live context in answers. A local 180-second
timer attempts updates during active, unpaused recording through the same
approved `ChatGPTLiveClient`. It skips empty or unchanged snapshots and avoids
competing with an answer or existing summary. Pause, stop and teardown cancel
the work. This is a local scheduling policy; it does not use the Responses API
`background` option. Raw capture remains local. Recognized transcript text and
prior current-meeting semantic memory are sent for summaries; notes and preparation accompany
explicit answer requests. Summary and answer calls consume the connected plan's
usage and have no alternate provider or billing fallback.

`LiveMeetingMemory` processes ordered source chunks of at most 16,000 characters,
including up to 800 characters of overlap, into at most 8,000 characters of
rolling semantic memory. Each update uses the prior memory and new source rather
than resending every earlier word. The memory cache is local to the live session.
Its identity includes account, model, reasoning effort, transport and policy;
source edits that change the cached prefix invalidate coverage. Summary calls
and their eventual answer pin one identity and validate it again before accepting
results. A changed account or selection cancels that build instead of silently
continuing with different credentials or settings. Normal socket replacement
and refresh still follow the transport rules above; "same client" does not
require keeping one physical socket alive for three minutes.

An Ask cancels and awaits a background update, flushes current speech, and checks
coverage immediately. A transcript of at most 16,000 characters is included fully
as raw text. Longer meetings use semantic memory, the complete latest 12,000 raw
characters, and up to 6,000 characters of exact question-relevant older excerpts.
Any uncovered older prefix is summarized before the final streamed answer.
The answer can therefore require additional summary calls, especially after a
long pause, an edit or a provider change. There is no one-total-call or unchanged
latency guarantee. Failed or incomplete summaries cannot become successful
coverage or a keyword-only substitute.

Processing every available source character is not a promise of lossless recall.
Summaries can omit details, exact excerpts are selective, and missing live-preview
audio remains a source gap. The answer prompt distinguishes quoted context from
instructions, preserves corrections/approval conditions, and warns against
treating an omission as evidence that something was never discussed. The UI
shows review progress, the background update time/error, and an optional context
snapshot published only for a completed answer. That snapshot belongs to the
answer made when the user asked; it is separate from later background updates.
See [the live-answer contract](live-answer.md) for all context limits.

## Selected project and event context

Google Calendar sign-in is a separate read-only calendar authorization. It does
not create another AI account, provider, billing path or model client. Explicit
event preparation is a private user draft in the Live database, frozen with the
recording's project/event association and included on Ask. The current-meeting
180-second summary still processes only that meeting's recognized transcript
and its own prior semantic memory.

Project context adds at most one historical meeting. The repository first
selects the actual latest eligible prior project row, then evaluates readiness;
an unavailable latest row cannot silently fall back to an older completed one.
`LiveProjectMeetingMemory` may prefetch a semantic brief when the selected
project is attached. Both prefetch and foreground preparation use the existing
pinned `LiveAnswerStreamSession`, complete-only chunk commits and the same
subscription-only transport rules. Ask preempts and awaits prefetch before
preparing fresh current context. A missing cached brief can add summary calls;
no unchanged-latency or one-total-call promise is made.

The final prompt labels the prior project's title/date/status and distinguishes
its summary, exact question-relevant excerpts, raw tail and notes from the
current call. Previously recorded actions have no independently verified current
completion status. Silence, a summary omission or a lack of current discussion
cannot establish that an action was missed, overdue, completed or cancelled.
Later explicit corrections take precedence; unresolved conflicts remain explicit.

The reference scope includes the selected project/row, readiness, effective
source hash, attribution/correction revision, metadata and notes. Edits, deletion
and membership/source changes invalidate cached reference memory and omit stale
model-facing conversation history. Source identity is re-read before dispatch
and before accepting the final answer; provider account/model/effort/transport/
policy remains pinned across every summary and answer. Old reference content
cannot continue through a changed scope or imported external memory/tools.
See [the Google Calendar/project contract](google-calendar-live.md) for identities,
limits and private storage. Installed native replays have qualified combined
calendar/preparation/latest-project answers and interrupted/normal chat saving.
The validation report separates their short raw-context fixtures, accelerated
long-media test and measured source revisions; existing benchmarks do not
establish general project-context speed or accuracy.

## Reproducible benchmark

Build the native harness with `swift build -c release --product
chatgpt-live-benchmark`. Run `login` once for the app's own browser authorization;
it verifies a completed streamed request and saves a first-inference report.
`benchmark --transport websocket --trials 5 --models 3 --output /absolute/report.json` discovers models,
explicitly probes `none`, `minimal`, `low`, then default effort when unsupported,
records failures, measures recent and long-meeting contexts repeatedly, and
selects the lowest measured worst-context p95 first-sentence latency among models
with complete sentence-bearing responses in every trial. Unsupported effort
probes are retained and are never repeated automatically on the live path.

Use `--transport http-sse` for explicit HTTP comparison. Every trial and summary
records its transport; the isolated `websocket --trials 5` experiment also
constructs its HTTP lane explicitly. Reports cannot infer transport from the
application default. The isolated experiment excludes its first socket handshake
from warm groups and always sends WebSocket before paired HTTP, an ordering caveat.

`idlecheck --seconds 180 --output /tmp/macparakeet-live-idlecheck.json` qualifies
an unused warm-up socket in one benchmark process. The idle interval is bounded
to 30–600 seconds. It uses the selected model/effort, calls production `warmUp()`
without a model request, waits, then sends exactly one synthetic recent-context
trial. A failed or empty response exits nonzero without retry. The standard report
retains its trials plus `idleCheck` metadata, including a safe failure message if
warm-up or the trial fails. This command is a qualification harness, never the
per-question application transport; no meeting data is read or sent.

Reports include model, transport, effort, OS, processor count, first text, punctuation-based
first sentence, completion, outputs, failures, median and nearest-rank p95. The
first inference in a process is identified separately; no claim is made that
the server or operating-system network cache was reset. Catalog retrieval and
rejected effort probes can already have warmed HTTP before the first inference.
Provider benchmarks
exclude audio, transcription, hotkey handling and UI rendering. Inspect outputs
before calling a sentence useful; punctuation is only an observable proxy.
Live Ask maintains separate freshness and request-to-display timings.

Saved comparisons through `d8d6477875b5`, and the existing bounded-context provider
fixtures, use the previous recent-text/extractive-anchor projection. They are
historical transport/answer baselines. They do not qualify the new periodic
summary traffic, semantic retention, background preemption or long-meeting
catch-up latency. Rolling-memory tests and installed qualification must report
those separately, including summary time before the final answer handoff.

## Governing sources

Verified against the official documentation on October 28, 2026:

- [Overview](https://developers.openai.com/siwc/token-sharing-open-source)
- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [Responses WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode)
- [Responses WebSocket events](https://developers.openai.com/api/reference/resources/responses/websocket-events)

Focused tests: `ChatGPTAuthTests`, `ChatGPTLiveClientTests`,
`ChatGPTWebSocketTransportTests`, `LiveMeetingMemoryTests`,
`LiveMeetingMemoryViewModelTests`, `LiveAnswerTests`.
Synthetic tests do not establish account eligibility, completed cloud inference,
microphone/system-audio capture, TCC authorization, or installed-app performance.

`contextcheck --model gpt-6-luna --transport websocket --output /absolute/report.json`
uses the saved model/effort selection and production pinned session. It advances
a synthetic meeting through 3/6/9/12-minute snapshots without wall-clock waits,
then asks two questions against its15-minute source. The report separates
summary update, context preparation and final answer timing, checks complete
source-range coverage/cache reuse, and retains synthetic outputs for review.
This qualifies memory and provider behavior; it does not measure native capture
or actual 180-second idle gaps.
