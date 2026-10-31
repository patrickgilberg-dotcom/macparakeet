# Immediate meeting focus and explicit answer refresh

Qualification dates: October 30–31, 2026 (America/Edmonton).
Installed source: `e602f5a2ebc7`, built at `2026-10-31T17:21:35Z`
(October 31 in Edmonton). The supported installation, source receipt and
strict/deep signature verification passed. Earlier source-specific results
below remain labeled `1136349991ae` and `fb7342b6e821`.

Status: **in progress — controlled native audio pending**. The installed
question-opener fallback passed 29 Core tests, the final 199-test focused gate
and its signed helper's cloud functional check. Two preceding native recordings
remain diagnostic because recognized punctuation/timing boundaries dropped
question openings; exclusive generated-audio input was not established.
The installed source's controlled A/B attempt was stopped normally after other
system audio entered capture. It saved its artifacts but did not test Update B,
so final controlled native qualification remains pending the user's choice to
pause other audio or finish later. No rerun will begin before that reply.
Original QA preferences and their presence are restored exactly, all 17
baseline meetings remain, and no recording lock is active. The **one full-suite
command failed** and did not produce an All Tests completion summary.

## Resulting behavior

An explicit live answer now receives three complementary layers: immediate raw
speech around the latest 30 seconds, extended to preserve the relevant complete
question or turn; the latest completed three-minute summary; and cumulative
general meeting memory. An explicit typed question remains the primary intent.
Fresh corrections and existing approval conditions remain authoritative.

Immediate context selection and freshness comparison are local. They add no
model-summary request to Ask or Update answer. A captured answer keeps a stable
question/turn anchor and context-capture time. Meaningful new discussion or a
correction can offer **Conversation moved on · Update answer** during or after
generation. It does not automatically regenerate on new words or elapsed time.
Silence alone does not make an answer stale.

Update refreshes the original intent against fresh recognized speech. During an
active request it cancels the old generation and reuses the admitted user turn;
after a completed answer it adds an explicit Update answer turn. Completed
answers remain readable, an unsent composer draft is preserved, and cancelled
partial text does not enter successful assistant history. Existing ownership,
checkpoint, source-gap and account/model guards remain in place.

The source-`fb7342b6e821` raw window backs up to a speaker change or a gap
of at least 2.5 seconds in recognized word timing, ignoring recognized
sentence punctuation. Native diagnostics showed a selected question opening
could be lost across numeric gaps; the origin of extra recognized speech was
not isolated. Installed source `e602f5a2ebc7` adds an English lexical fallback:
within a three-minute lookback, a recognized sentence's direct question or
request opener can retain same-speaker continuations across periods and timing
gaps. A newer explicit question, topic/status assertion or substantial
completed declarative can reset the anchor; hard boundaries preserve the
newer question's priority. Ambiguous status boundaries can retain earlier exact
raw source while the status turn takes anchor priority.

These local timing and lexical rules are not semantic parsing or a universal
turn detector. Short declaratives and closely spoken turns can coalesce. Raw
source remains available separately, with the unchanged 12,000-character bound
and explicit omission marker. An anchor can be classified as a question without
a question mark; its complete flag requires recognized ending punctuation and
unclipped source. A period can satisfy that flag. This does not guarantee
perfect recognition or semantic completeness.

## Focused evidence

The initial default-symbol build ran out of temporary disk space while
producing debug symbols, before tests ran. It reported no Swift source error.
The focused gate was rebuilt in **Debug with `-debug-info-format none`**;
assertions remained enabled. Source `1136349991ae` passed **189 tests**, zero
failures, in **9.749 seconds**. After a native diagnostic showed a
punctuation boundary dropping a question opening, source `fb7342b6e821` passed the
expanded gate: **193 tests**, zero failures, in **10.007 seconds**. The four
additional cases cover that boundary correction. These successive gates cover
overlapping tests. Reducing debug symbols is not an optimized Release
qualification or a change to production capture behavior.

Fallback development initially produced **10 assertion failures across five
Core tests** in an earlier 199-test run. Sentence-based opener selection and
reviewed boundary guards resolved those failures. The final committed source
`e602f5a2ebc7` passed **29 Core tests** in **0.016 seconds**, then **199 focused
tests**, zero failures, in **9.875 seconds** using the freshly built binary.
This final gate used **Debug with debug symbols and assertions retained**.
The earlier default-symbol build attempt was stopped before tests; the resumed
Core and focused invocations ran against the fresh final binary. These focused
gates cover overlapping tests and do not replace the failed full-suite run.

Coverage includes immediate-window boundaries, complete questions longer than
30 seconds and rendering paragraph limits, silence and acknowledgements,
source corrections, attribution changes, partial tokens, explicit status
changes, atomic snapshots, active and completed refresh, typed intent/draft
preservation, cancellation, late output and terminal-save ordering.

## Genuine ViewModel/cloud functional check

At source `1136349991ae`, the already authorized, persistently signed helper
ran `freshnesscheck` using the production ViewModel and Update action with
generated numeric word fixtures. No user meeting database, audio, transcript,
skill, preparation or writing example was read for the synthetic source. The
full synthetic report is retained privately as `QA/2026-10-30-now-focus/cloud-freshnesscheck.json`.

The helper exited successfully after **five terminal-completed requests**:
**three summary requests** to prepare the caches and **two explicit answers**.
Both answers made **zero summary calls during foreground preparation**.
The 32.25-second complete question retained its beginning from before the
30-second cutoff; the initial immediate source spanned 14:20–15:00. Three-minute
and general summaries remained separate inputs.

The first answer used the corrected synthetic ceiling of **$38,000** and said
that Friday's production launch was not approved. The report's
`answer_denies_unapproved_launch` lexical marker remains **false**: its literal
phrases missed the actual curly-apostrophe wording “isn’t approved.” Manual
review confirms the output denied approval and retained the security-approval
condition. This is a heuristic false negative, not an all-green lexical result;
the original flag was not rewritten.

A new complete question marked the answer as superseded. Answer-call count
remained **one before and after that notification**, proving the notification
did not start inference. Explicit Update produced the second completed answer,
which named the synthetic route owner and retained the corrected ceiling.
The latest question became the new anchor, the moved-on flag cleared for that
snapshot, and the earlier completed answer remained visible. Structural checks
also confirmed an explicit new visible user turn for completed-answer refresh.

These observations used a Debug executable without debug symbols and overlapped
build/test activity. They qualify data flow and terminal completion, **not**
native Release latency, real microphone/system-audio capture, or a wall-clock
180-second summary cadence.

The persistently signed helper rebuilt from `fb7342b6e821` then completed a
fresh run with **exit 0**. Its separate private report is
`QA/2026-10-30-now-focus/fb7342b6-cloud-freshnesscheck.json`. All **five requests**
completed terminally: **three summaries and two explicit answers**, with **zero
foreground summary calls** on either answer. The generated 32.25-second
question retained its beginning, both completed summaries were present, and
the new-question notice left answer-call counts at **one before and one after**.
Explicit Update used the fresh anchor and kept the previous completed answer.

All functional markers passed except the same preserved lexical approval
marker: the literal matcher again missed “isn’t approved.” Manual review
confirms the answer denied launch approval. This newer run does not rewrite
the earlier report or its marker.

| Helper action at `fb7342b6e821` | First text | First sentence | Completion |
| --- | ---: | ---: | ---: |
| Ask | 841 ms | 1,578 ms | 1,907 ms |
| Update answer | 1,221 ms | 1,550 ms | 1,773 ms |

These rounded invocation timings describe the Debug signed helper with
numeric transcript fixtures. They do not measure native rendering, speech
recognition, system-audio capture or acoustic-end latency.

The signed helper rebuilt from fresh Debug `e602f5a2ebc7` completed a new
check with **exit 0**. Its separate private report is
`QA/2026-10-30-now-focus/e602f5a2-cloud-freshnesscheck.json`. All **five requests**
completed terminally: **three summaries and two explicit answers**, with **zero
foreground summary calls** on either answer. The numeric-fixture checks passed
for the 32.25-second question, separate three-minute/general inputs, unchanged
answer-call counts (**one before and one after** the notice), fresh explicit
Update anchor and retained old answer.

The lexical approval marker remains **false**. In this run the actual answer
said Friday's production launch **“cannot be promised”**, retained the corrected
**$38,000** ceiling, and said that the ceiling had not been approved and
security approval was required. The literal matcher did not cover this denial wording; manual
semantic review passed. This is a distinct phrase from the earlier runs'
curly-apostrophe “isn’t approved,” and those earlier flags remain unchanged.

| Helper action at `e602f5a2ebc7` | First text | First sentence | Completion |
| --- | ---: | ---: | ---: |
| Ask | 1,340 ms | 1,685 ms | 3,536 ms |
| Update answer | 1,477 ms | 1,809 ms | 2,071 ms |

These rounded Debug-helper invocation timings and generated word fixtures
prove current-source cloud data flow and completion. They do not qualify
native rendering, real speech recognition or system-audio capture.

## Full-suite failure and focused diagnostic rerun

At source `1136349991ae`, the **one full-suite command finished with exit
status 1**. In the existing CLI suite,
`TransformsCommandTests.testRunRecordsTransformHistory` timed out: its configured
timeout was **300 seconds**, with **450.661 seconds** observed wall
time. The XCTest host then aborted with **signal 6**, reporting
`NSFileHandleOperationException` for a closed file descriptor in
`LocalCLIExecutor.writePromptData`.

There is no All Tests completion summary. Do not claim that all XCTest cases
ran or that the full suite passed. The separate Swift Testing run passed its
**30 tests**, but that does not turn the failed XCTest invocation into a pass.

The run also experienced long suspension/resource periods. Stack inspection
showed 64 blocked AppKit/NSAnimation workers. Earlier, the existing
`TranscriptionServiceTests.testTranscribeMeetingUsesValidatedCleanedMicForMicrophoneSource`
passed after **2,085.208 seconds**; its entire class passed before CLI execution
continued. These observations are evidence of the run's environment, not proof
of the sole cause of the timeout or file-descriptor exception.

A fresh focused rerun of `LocalCLIExecutorTests` and `TransformsCommandTests`
passed **90 tests**, zero failures, in **17.950 seconds**. The previously timed
out transform-history case passed in **0.321 seconds**. This result is retained
alongside the failure; it does **not** erase or replace the failed full run.

No legacy runner code was changed for this feature. The new direct ChatGPT
Ask/Update path does not use that optional CLI-subprocess route. A sound change
to its I/O ownership would require a separately reviewed refactor rather than
being silently folded into the meeting-context update. The full suite was not
repeated for this task.

## Installed build and native diagnostic

The first feature Release workflow built source `1136349991ae`, and the
installer completed with a matching source receipt. Before native QA,
strict/deep signature verification passed. A private consistent database
backup passed its integrity check. All **17 baseline meeting IDs** were
retained, the saved preferences-file hash and original MacParakeet executable
hash were unchanged, and no recording lock remained. These checks predate the
new diagnostic recording and temporary QA preferences.

After unlock, the installed source `1136349991ae` completed a **5:34 native
system-audio-only recording**. A real 180-second tick produced both the
three-minute and general summaries. The recording had zero microphone bytes,
no calendar-event association and no project. Generated test speech was played
into all-system-audio capture, using local calendar exclusions and All Meetings
with recording URL control disabled. Other system speech was not excluded,
and exclusive generated-audio input was not established. It did not modify real events, per-event preparation or real project
membership.

The native Ask and Update button completed actual answers. Times below run
from answer invocation, not from the acoustic end of speech:

| Native action at `1136349991ae` | First text | First sentence | Completion |
| --- | ---: | ---: | ---: |
| Ask | 1.9211 s | 2.1631 s | 3.1987 s |
| Update answer | 1.9291 s | 2.1846 s | 2.6161 s |

Forty-three seconds of silence did not mark the answer stale. A distinct new
question showed the moved-on notice without starting inference. Clicking
Update answer used the new question correctly and retained the previous
completed answer. Normal Stop saved audio, transcript and chat, with one
recovery receipt; saved audio decoded successfully.

However, the recognized output around the roughly 37-second test question
contained internal periods. Its raw Now span and anchor began at 3:33 instead of preserving
the opening at 3:13, dropping an early question clause. The retained recording
is named **QA Now Focus Boundary Check**. This defect makes the run diagnostic,
not a pass for the requested complete-question behavior.

Source `fb7342b6e821` added the punctuation-aware raw and anchor boundaries
described above and passed the 193-test focused gate. Its signed Release was
built at `2026-10-31T03:54:23Z`, installed, and passed strict signature verification.
The native attempt started at `03:54:49Z`; the Mac locked during startup. At
`03:55:03Z`, capture metadata reported `system_audio_stream_start_failed`
(`MeetingAudioError.systemAudioCaptureFailed`, code 2). No recording was
persisted and no active recording lock remained. This is a failed startup
attempt, not a qualified corrected-build recording; the observed lock does not
establish the sole cause of the capture error.

The host then paused overnight, and tools resumed at `2026-10-31T16:36Z`
(October 31 locally). Before the later unlocked attempt, the original
audio-source and calendar-exclusion values and their presence were restored
exactly from the private snapshot; the other three checked QA keys were
unchanged. At that stage, all 17 baseline meetings plus the first diagnostic
remained (**18 rows**), and the app was ordinarily quit with no active recording.

After user unlock, `fb7342b6e821` completed a second native recording lasting
**383.5 seconds**, saved as **QA Now Focus Gap Boundary Check**. The real
180-second tick produced both completed summaries covering **0:00–2:59**.
Capture used system audio only, with zero microphone bytes, no calendar event
and no project.

| Native action at `fb7342b6e821` | First text | First sentence | Completion |
| --- | ---: | ---: | ---: |
| Ask | 2.4576 s | 2.7136 s | 3.7961 s |
| Update answer | 1.8035 s | 2.0606 s | 2.2525 s |

These are invocation timings for this diagnostic. At least **81 seconds of
silence** did not mark the answer stale. A later question offered Update while
the answer count remained one. The actual Update answered that question with
its full preamble, retained the old answer and preserved an unsent composer
draft. Normal Stop saved transcript and chat in user/assistant/user/assistant
order, with one recovery receipt; saved audio passed strict decoding.

The long-question check still failed. Recognized output contained periods,
and numeric word timings contained gaps exceeding 2.5 seconds. The resulting
Now span was only **3:37–4:13**, beginning on a middle clause rather than the
opening at **3:11**. These are observed selection boundaries; speech-recognition
behavior and mixed system audio were not isolated as possible origins of the
extra recognized speech. The run does not prove a sole ASR cause or exclusive
generated-audio capture. Punctuation-aware extension alone therefore did not
qualify the requested complete-question behavior. The bounded opener fallback
is committed and installed at `e602f5a2ebc7`, with its final controlled native
result still pending.

Automatic minutes for this second diagnostic initially rejected an unverified
action quote. No invalid minutes were published. A later explicit retry
completed with validated output; the initial rejection remains part of the
history rather than being rewritten as a first-attempt success.

The signed `e602f5a2ebc7` Release was built at `2026-10-31T17:21:35Z` and
installed through the supported workflow, with its source receipt and
strict/deep signature verified. Its manual system-audio-only native attempt
started at `17:22:20Z`. Other live system audio entered the recording after
the generated clip, so the controlled A/B scenario was stopped normally after
**307.9 seconds**. The recording had no calendar association or project.
No Update-B action was tested. The retained capture is private and includes
non-synthetic audio; no conversation or AI output from it is reproduced here.

Normal Stop completed one new database row, with two chat turns in
user/assistant order. Saved audio passed strict decoding. These structural
artifact checks establish normal saving, not a completed controlled native
question/Update scenario.

The library now contains **20 rows**: all **17 baseline meetings**, the two
diagnostics and the interrupted recording. Database `quick_check` passed and
there are **zero active recording locks**. The two modified QA preference keys
were restored to their original values and presence; all five checked keys
and their presence match the original snapshot. Recording URL control remained
disabled. The app was ordinarily quit with no active capture.

Final controlled native qualification awaits the user's choice to pause other
calls/videos or finish later. No rerun will begin before that reply. The plan
remains in progress.

The public source-specific evidence is recorded in
[the qualification file](../benchmarks/chatgpt-live/results/2026-10-30-now-focus-refresh-e2e.json).
Native qualification remains pending a controlled UI/audio rerun of the
installed opener fallback. Neither diagnostic nor the interrupted mixed-audio
recording qualifies that final result.

## Privacy and limits

A read-only review of the new Core projection, tests and helper found generated
fixtures and no private skill, email body, account identifier or credential in
the added source. Actual recordings, backup files and authentication material
remain outside this report and the repository.

The full XCTest run is not green. The preceding native diagnostics exposed
question-selection boundaries without isolating recognition from other system
speech. The installed opener fallback passed focused tests and synthetic cloud
checks; its latest native attempt saved normally but was interrupted by other
system audio before Update B. Final controlled native qualification remains
pending. Original preferences are restored and capture is stopped. Source tests,
helper calls and structural artifact checks do not substitute for that missing
controlled interaction result.

Both summaries are lossy, local recognition can miss words, and the local
conversation-moved-on heuristic is not a guarantee of semantic topic detection.
Capture, recovery, calendar/project and prior minutes/style evidence retains
its original revision labels in [the main report](macparakeet-live-validation.md)
and [the preceding focus report](macparakeet-live-focus-validation.md). None of
those earlier results substitutes for the still-pending native refresh test.
