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

Every `/v1/responses` request sends `store:false`, `stream:true`, explicit input
history, and instructions. Unsupported sampling/token/storage fields are omitted.
There are no tools in the default live request. Reasoning effort is sent only
when explicitly selected by a successful capability experiment; the catalog does
not promise a reasoning-effort schema. Redirects are refused.

The byte-level SSE decoder preserves blank-line boundaries, CR/LF and split
Unicode. Text deltas are yielded as soon as their event finishes. Only
`response.completed` produces a successful terminal event. Failures, usage
limits, incomplete events, malformed framing, EOF and cancellation cannot mark
a partial answer complete. The UI marks failed partial answers incomplete.

## Reproducible benchmark

Build the native harness with `swift build -c release --product
chatgpt-live-benchmark`. Run `login` once for the app's own browser authorization;
it verifies a completed streamed request and saves a first-inference report.
`benchmark --trials 5 --models 3 --output /absolute/report.json` discovers models,
explicitly probes `none`, `minimal`, `low`, then default effort when unsupported,
records failures, measures recent and long-meeting contexts repeatedly, and
selects the lowest measured worst-context p95 first-sentence latency among models
with complete sentence-bearing responses in every trial. Unsupported effort
probes are retained and are never repeated automatically on the live path.

Reports include model, effort, OS, processor count, first text, punctuation-based
first sentence, completion, outputs, failures, median and nearest-rank p95. The
first inference in a process is identified separately; no claim is made that
the server or operating-system network cache was reset. Provider benchmarks
exclude audio, transcription, hotkey handling and UI rendering. Inspect outputs
before calling a sentence useful; punctuation is only an observable proxy.
Live Ask maintains separate freshness and request-to-display timings.

## Governing sources

Verified against the official documentation on October 27, 2026:

- [Overview](https://developers.openai.com/siwc/token-sharing-open-source)
- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)

Focused tests: `ChatGPTAuthTests`, `ChatGPTLiveClientTests`, `LiveAnswerTests`.
Synthetic tests do not establish account eligibility, completed cloud inference,
microphone/system-audio capture, TCC authorization, or installed-app performance.
