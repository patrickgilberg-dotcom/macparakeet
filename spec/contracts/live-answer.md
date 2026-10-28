# MacParakeet Live meeting answers

This personal fork retains local recording, durable audio, final transcription,
notes, and the existing live Ask panel. Live Ask uses `ChatGPTLiveClient` directly;
it never selects an API-key provider, CLI, connector, or agent fallback.

- Help me answer this and custom questions each perform one streamed model call.
  The global shortcut is Option-Command-Space while a meeting is active, using
  macOS registered hotkeys without broad keyboard monitoring. If another app or
  system shortcut owns that chord, Control-Option-Command-Space is attempted and
  displayed in Ask. Registration failure is visibly unavailable; it does not
  change privacy permissions. Recording teardown unregisters the shortcut, and
  delayed events cannot reach a later recording. Escape or Stop cancels a
  request. A new explicit Help request cancels the old one before preparing its
  own transcript.
- Before inference, active capture sources cross the invocation's host timestamp.
  The service drains preview ingest, pauses only preview ingest while owning the
  single-caller VAD/chunker boundary, flushes paired audio and all pending tails
  including tails shorter than 500 ms, then waits for the captured STT tasks.
  Durable capture continues. Sample counters are never reset, and input is never
  padded with synthetic silence. A changed session, failed recognition, dropped
  preview work, or an eight-second preparation deadline declines the request
  with a visible error. A timed-out recognition remains owned by its session.
  Preview loss before invocation also blocks an implicit latest-question answer.
  Each source keeps a loss frontier: empty recognition, other-source speech and
  work enqueued before the loss cannot clear it. Only newly enqueued nonempty
  speech from the same source clears that source's frontier. Ingress loss first
  drains its admitted backlog before fixing the frontier. Recovery means newer
  speech exists; earlier missing words remain disclosed in Ask context/UI and
  are not represented as reconstructed. New sessions reset the frontier.
- Context includes at most 12,000 recent transcript characters, 4,000 extractive
  older anchors, 6,000 notes characters, 6,000 local preparation characters, and
  4,000 prior-chat characters. Opening lines and lines containing decisions,
  constraints, ownership, dates or amounts provide older anchors. This selection
  is incomplete by design; important account facts belong in preparation/notes.
  The complete saved transcript remains unchanged and available locally.
- Live answers reuse a native authenticated WebSocket with one serialized
  implicit lane. Every request sends the full bounded history and `store:false`;
  optional named lanes and `previous_response_id` are omitted. Any future
  continuation IDs must remain on the same authenticated connection. Account,
  model, token or expiry/55-minute age changes require a fresh socket before
  reuse; cancellation and incomplete responses close the old socket. A sent or
  partial request is never automatically replayed. HTTP/SSE remains an explicit
  comparison mode, with no automatic transport or billing fallback. The detailed
  transport contract is [ChatGPT plan usage](chatgpt-plan-usage.md).
- Preparation is saved in the isolated app preferences and sent only on an
  explicit request. Signing in does not import ChatGPT or Servant memory/tools.
- Text deltas render during streaming. An interrupted direct response remains
  visible as `[Incomplete response]` and does not enter successful model history.
  Only terminal success is persisted as an assistant turn. Cancelled generations
  cannot update a newer request's output or timing.
- Local diagnostic events record recognition duration, preview audio-end age at
  transcript commit, and invocation-to-transcript-ready/first-text/first-sentence/
  completion. Preview age uses the active recording sample timeline, not a
  measured acoustic speech boundary. First sentence means the first observed
  punctuation/newline boundary after 12 characters; usefulness needs human
  evaluation. These metrics do not claim either speed target has been achieved.

Focused coverage: `LiveAnswerHotkeyTests`, `LiveAnswerTests`, `AudioChunkerTests`,
`SpeechBoundaryMeetingLiveAudioChunkerTests`, `LiveChunkTranscriberTests`, and
the live-answer cases in `MeetingRecordingServiceTests`. Scripted audio and
mocked streams verify ordering/cancellation; actual device capture and cloud
latency must be verified separately in the installed Release app.
