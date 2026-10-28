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
are refused. No transport automatically replays a failed or possibly accepted
request, and neither can switch to a different billing path.

The socket actor grants one exclusive FIFO request lease on the implicit default
lane. It omits optional `stream_id`: the signed native SIWC route rejected named
lanes with HTTP 400 while the otherwise equivalent unnamed control completed.
General Responses multiplexing documentation does not establish that optional
field's compatibility with this route. Each turn obtains current credentials after acquiring that lease. Reuse
requires the same account, model, access-token fingerprint, and live connection
generation, plus a native task that is still running with no close code. A known
closed idle socket is retired before sending the next request, without replaying
a request against it. Token rotation, the conservative token-expiry reuse margin, or a
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

The spoken opening targets 8–12 words with an 18-word maximum, followed by at
most two supporting bullets. Accuracy and necessary conditions take priority;
output is never mechanically truncated to force a word count.

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

Reports include model, transport, effort, OS, processor count, first text, punctuation-based
first sentence, completion, outputs, failures, median and nearest-rank p95. The
first inference in a process is identified separately; no claim is made that
the server or operating-system network cache was reset. Catalog retrieval and
rejected effort probes can already have warmed HTTP before the first inference.
Provider benchmarks
exclude audio, transcription, hotkey handling and UI rendering. Inspect outputs
before calling a sentence useful; punctuation is only an observable proxy.
Live Ask maintains separate freshness and request-to-display timings.

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
`ChatGPTWebSocketTransportTests`, `LiveAnswerTests`.
Synthetic tests do not establish account eligibility, completed cloud inference,
microphone/system-audio capture, TCC authorization, or installed-app performance.
