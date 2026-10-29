# MacParakeet Live meeting answers

This personal fork retains local recording, durable audio, final transcription,
notes, and the existing live Ask panel. Live Ask uses `ChatGPTLiveClient` directly;
it never selects an API-key provider, CLI, connector, or agent fallback.

- Help me answer this and custom questions prepare whole-meeting context and then
  perform one final streamed answer call. Periodic and catch-up summaries can
  make additional model calls through the same approved ChatGPT client.
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
- The live assembler and panel retain all recognized preview text for the session;
  there is no fifteen-minute or visible-timeline cutoff before context preparation.
  Processing coverage refers to available recognized text, not missing audio or
  a guarantee that a summary preserves every fact. Durable audio and the complete
  saved transcript remain unchanged.
- During active, unpaused recording, a local timer attempts a rolling summary
  update every 180 seconds. This background cloud processing was explicitly
  authorized for this fork. Empty or unchanged snapshots are skipped, and a tick
  does not compete with an active answer or summary. Pause, stop and teardown
  cancel periodic work. An explicit Ask cancels and awaits background work before
  preparing its fresh transcript and context; it does not wait for the next tick.
- Semantic memory processes the available source in ordered chunks of at most
  16,000 characters, including up to 800 characters of overlap, and retains a
  rolling summary of at most 8,000 characters. Prompts preserve material facts,
  attribution, corrections, decisions, proposals, uncertainty and approval gates.
  This is a lossy summary, not a verbatim copy or an exhaustive fact index.
- For a transcript of at most 16,000 characters, Ask includes all raw text. For
  longer transcripts, it includes semantic memory covering the earlier source,
  the complete latest 12,000 raw characters, and up to 6,000 characters of exact
  older-source excerpts selected for the question. Memory can overlap the raw
  tail. If the unsummarized prefix is too large, Ask performs catch-up summary
  calls before answering rather than silently dropping it. Excerpt retrieval
  supplements semantic coverage; it never substitutes for a failed summary.
  Notes and local preparation each retain their 6,000-character limit, and prior
  chat retains its 4,000-character limit. These are text limits, not time windows.
- Each memory build and answer pins the recording's ChatGPT account/model/effort/
  transport/policy identity. A changed identity, reset or non-append transcript
  edit invalidates cached coverage. Only terminal-completed, useful summaries
  advance it; empty, oversized, failed or cancelled output cannot establish full
  coverage. Known source gaps remain explicit and are not reconstructed. A
  failed background update is visible, and the next Ask retries required context
  rather than pretending that older text was covered.
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
  explicit answer request, alongside notes. Automatic summary updates send
  recognized transcript text and prior meeting memory to the approved ChatGPT
  connection; they do not send raw audio. Rolling memory is held in this live
  session's process, not imported ChatGPT or Servant memory/tools.
- Ask shows review progress and the last successful background update or its
  error. The optional context disclosure belongs to the last completed answer:
  it identifies full raw context or shows that answer's earlier summary, plus
  recent speech captured when Ask was pressed. It is not the continuously
  updating background summary. Summary omissions are disclosed, and the source
  transcript remains necessary for exact earlier wording.
- Text deltas render during streaming. An interrupted direct response remains
  visible as `[Incomplete response]` and does not enter successful model history.
  Only terminal success is persisted as an assistant turn. Cancelled generations
  cannot update a newer request's output or timing.
- Local diagnostic events record recognition duration, preview audio-end age at
  transcript commit, and invocation-to-transcript-ready/context-ready/request/
  first-text/first-sentence/completion. Context preparation includes any summary
  catch-up; request-to-first-text begins at the final answer handoff. Periodic
  summary diagnostics record outcomes and source character counts, not content.
  Preview age uses the active recording sample timeline, not a
  measured acoustic speech boundary. First sentence means the first observed
  punctuation/newline boundary after 12 characters; usefulness needs human
  evaluation. These metrics do not claim either speed target has been achieved.

Focused coverage: `LiveMeetingMemoryTests`, `LiveMeetingMemoryViewModelTests`,
`LiveAnswerHotkeyTests`, `LiveAnswerTests`, `AudioChunkerTests`,
`SpeechBoundaryMeetingLiveAudioChunkerTests`, `LiveChunkTranscriberTests`, and
the live-answer cases in `MeetingRecordingServiceTests`. Scripted audio and
mocked streams verify ordering/cancellation; actual device capture and cloud
latency must be verified separately in the installed Release app. Earlier saved
performance reports used the prior 12,000-character recent/4,000-character
extractive-anchor policy; they do not measure periodic summaries, semantic
retention or catch-up latency. Qualification of this rolling-memory policy is
recorded in [the validation report](../../docs/macparakeet-live-validation.md):
focused and full tests pass, the signed Release app is installed, and the
synthetic cloud memory/answer flow completed. The native 180-second wall-clock
cadence and capture-to-answer timing were not re-measured in this revision.
