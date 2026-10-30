# MacParakeet Live meeting answers

This personal fork retains local recording, durable audio, final transcription,
notes, and the existing live Ask panel. Live Ask uses `ChatGPTLiveClient` directly;
it never selects an API-key provider, CLI, connector, or agent fallback.

An optional personal answer-style profile is read from the saved isolated
preferences for each explicit Ask. Its instructions and approved writing
samples are bounded user-data JSON, not meeting evidence. Stable system rules
keep the spoken opening, factual sources, uncertainty and approval conditions
ahead of wording preferences. Samples are not added to chat history or supplied
to current/project memory summaries or final meeting minutes. Disabling the
profile preserves the established request shape. ChatGPT sign-in does not import
account conversations or personal memory. The editable starter reflects only
the user's requested concise, direct wording; no biography or example messages
are invented. See [meeting preferences](live-meeting-preferences-v1.md).

- Help me answer this and custom questions prioritize the latest completed
  three-minute focus summary and fresh speech, while retaining general meeting
  memory as background. An explicit question about earlier discussion can use
  that background and exact excerpts. They prepare current context and then
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
- During active, unpaused recording, a local timer attempts two complementary
  summary updates every 180 seconds: cumulative general memory and a separate
  recent focus summary. This background cloud processing was explicitly
  authorized for this fork. Unchanged source/window snapshots are skipped, and a tick
  does not compete with an active answer or summary. Pause, stop and teardown
  cancel periodic work. An explicit Ask cancels and awaits background work before
  preparing its fresh transcript and context; it does not wait for the next tick.
- Recent focus uses the recognized words overlapping the latest 180 seconds on
  the recording timeline, including a word that straddles the start boundary.
  Numeric word timestamps select this source independently of plain/rich text
  preferences; formatted paragraph timestamps are not used to guess a window.
  A focus update processes the selected source in chunks of at most 16,000
  characters with up to 800 characters of overlap, returning at most 3,000
  characters of window-only memory. It never absorbs general memory, event
  preparation, project history, personal style or writing samples.
- Ask reuses the latest completed focus summary with its actual start/end times;
  it does not make a fresh focus-summary call on every question. This is a
  completed three-minute snapshot, not a promise of a newly summarized sliding
  window ending at invocation. Fresh recognized speech is included immediately
  and takes priority for corrections and the latest question. A focus summary
  outside the current recent window is omitted, and silence ages old focus out
  even when the full transcript text has not changed. Before a focus summary is
  ready, Ask uses available current speech and labels the summary unavailable.
- Semantic memory processes the available source in ordered chunks of at most
  16,000 characters, including up to 800 characters of overlap, and retains a
  general summary of at most 8,000 characters. Prompts preserve material facts,
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
  Those complete-source safeguards remain in addition to recent focus. Before
  the first general update, a short meeting can have no general summary; its
  available full transcript supplies background instead of a fabricated summary.
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
- Notes/session preparation and the selected event's privately saved preparation
  accompany explicit answers. Per-event drafts and project membership live in
  the isolated Live database; they are user-authored records, not a polling cache
  of Google Calendar. A recording freezes its event context/project association
  at start and preserves the exact calendar title against automatic renaming.
  Automatic three-minute updates send only recognized current-meeting text and,
  for general memory, that meeting's prior general summary. The focus summary
  uses only its own selected recent source. Neither absorbs project history or
  sends raw audio. Both remain scoped to this live session's process.
- A selected project can add one separately labeled historical reference: the
  actual latest eligible prior project meeting before this recording began.
  Selection happens before readiness checks. A processing, failed, cancelled or
  empty latest row stays visibly unavailable; no older completed row substitutes
  for it. A separate prefetch builds its brief using the same pinned ChatGPT plan
  client, and Ask cancels/awaits that work, re-reads the source and adds semantic
  memory plus exact question-relevant excerpts. Source hashes, corrections,
  notes, membership and deletion changes invalidate that reference and its
  model-facing history scope. Historical action completion is unverified unless
  explicit evidence updates it; omission does not establish a missed action.
  The detailed Google/event/project boundary is
  [Google Calendar and project context](google-calendar-live.md).
- Ask shows review progress and the last successful background update or its
  error. The optional context disclosure belongs to the last completed answer:
  it shows that answer's recent focus and actual completed window, plus general
  meeting background, including when the full raw transcript was available.
  Missing summaries are labeled explicitly. It also identifies raw/summary
  coverage and includes recent speech captured when Ask was pressed. It is not
  the continuously updating background summary. Summary omissions are disclosed, and the source
  transcript remains necessary for exact earlier wording.
- Text deltas render during streaming. An interrupted direct response remains
  visible as `[Incomplete response]` and does not enter successful model history.
  Only terminal success is persisted as an assistant turn. Cancelled generations
  cannot update a newer request's output or timing.
- Live questions and completed assistant turns are checkpointed locally under
  the recording's stable conversation ID before normal Stop creates a Library
  row. A local checkpoint failure is reported separately from completed cloud
  inference. End awaits the serialized write/rollback chain and still stops
  capture if saving fails, retaining the recovery lock. Recovery inserts the
  conversation only when absent and preserves existing user edits; it never
  repeats inference. See [recording recovery](meeting-recovery-retention.md).
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
synthetic cloud memory/answer flow completed. Later native calendar/project
replays verified completed combined answers, fresh corrections, three/six-minute
context refreshes, normal saving and interrupted chat recovery. Their short
transcripts fit raw context; they do not measure long native semantic compaction
or establish acoustic speech-end timing. The validation report identifies each
measured revision and the additional focused calendar-startup repair separately.

The separate recent-focus/general-background policy is tracked in
[its implementation plan](../../plans/active/2026-10-30-live-three-minute-focus.md).
Its focused checks, signed build and installed qualification are pending; the
earlier revision evidence above does not qualify this new request shape.
