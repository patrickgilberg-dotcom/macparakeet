# Immediate meeting focus and explicit answer refresh

Qualification dates: October 30–31, 2026 (America/Edmonton).
Installed correction source: `fb7342b6e821`, built at
`2026-10-31T03:54:23Z` (October 30 in Edmonton). Installation and strict
signature verification passed. The preceding feature build `1136349991ae`
was built at `2026-10-31T00:56:46Z`, also October 30 locally.

Status: **in progress**. The correction passed 193 focused tests. The original
feature passed real-ViewModel synthetic cloud checks, installation, signature
and saved-data checks. A real native recording verified the summary timer and
explicit refresh flow, but exposed a long-question boundary defect corrected
in `fb7342b6e821`. That recording is diagnostic, not final qualification. The
corrected build is installed, and original QA preferences are restored. Its
native attempt failed to start system capture while the Mac locked; final
native interaction qualification remains pending unlock and rerun. The fresh
signed helper at the correction source completed its cloud functional check.
The **one full-suite command failed** and did not produce an All Tests
completion summary.

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

The corrected raw window backs up to the beginning of the overlapping
utterance, using a speaker change or a pause of at least 2.5 seconds as its
boundary. Recognition-inserted periods do not truncate that span. The anchor
can retain the question's same-utterance lead-in and conditions; a later
capitalized interrogative after a prior question can establish a new anchor.
These are local timing and lexical rules, not semantic parsing, and may
coalesce closely spoken turns. The raw source remains available separately.
Pathological source beyond the 12,000-character immediate-context bound is
marked shortened and incomplete. A complete flag does not guarantee perfect
speech recognition.

## Focused evidence

The initial default-symbol build ran out of temporary disk space while
producing debug symbols, before tests ran. It reported no Swift source error.
The focused gate was rebuilt in **Debug with `-debug-info-format none`**;
assertions remained enabled. Source `1136349991ae` passed **189 tests**, zero
failures, in **9.749 seconds**. After the native diagnostic exposed recognition
punctuation splitting a spoken question, source `fb7342b6e821` passed the
expanded gate: **193 tests**, zero failures, in **10.007 seconds**. The four
additional cases cover that boundary correction. These successive gates cover
overlapping tests. Reducing debug symbols is not an optimized Release
qualification or a change to production capture behavior.

Coverage includes immediate-window boundaries, complete questions longer than
30 seconds and rendering paragraph limits, silence and acknowledgements,
source corrections, attribution changes, partial tokens, explicit status
changes, atomic snapshots, active and completed refresh, typed intent/draft
preservation, cancellation, late output and terminal-save ordering.

## Genuine ViewModel/cloud functional check

At source `1136349991ae`, the already authorized, persistently signed helper
ran `freshnesscheck` using the production ViewModel and Update action with
generated numeric word fixtures. No user meeting database, audio, transcript,
skill, preparation or writing example was read for the synthetic source. The full synthetic report
is retained privately as `QA/2026-10-30-now-focus/cloud-freshnesscheck.json`.

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
no calendar-event association and no project. The test used synthetic speech,
local calendar exclusions and All Meetings, with recording URL control left
disabled. It did not modify real events, per-event preparation or real project
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

However, the roughly 37-second spoken question acquired internal periods from
recognition. Its raw Now span and anchor began at 3:33 instead of preserving
the opening at 3:13, dropping an early question clause. The retained recording
is named **QA Now Focus Boundary Check**. This defect makes the run diagnostic,
not a pass for the requested complete-question behavior.

Source `fb7342b6e821` corrects the raw and anchor boundaries as described above
and passed the 193-test focused gate. Its signed Release was built at
`2026-10-31T03:54:23Z`, installed, and passed strict signature verification.
The native attempt started at `03:54:49Z`; the Mac locked during startup. At
`03:55:03Z`, capture metadata reported `system_audio_stream_start_failed`
(`MeetingAudioError.systemAudioCaptureFailed`, code 2). No recording was
persisted and no active recording lock remained. This is a failed startup
attempt, not a qualified corrected-build recording; the observed lock does not
establish the sole cause of the capture error.

The host then paused overnight, and tools resumed at `2026-10-31T16:36Z`
(October 31 locally). User unlock is pending. The original audio-source and
calendar-exclusion preference values and their presence have now been restored
exactly from the private snapshot; the other three checked QA keys were
unchanged. Recording URL control remains disabled. The library retains all
17 baseline meetings plus the one diagnostic recording, for **18 rows**. The
app was ordinarily quit with no active recording.

A fresh native long-question/Update-button recording and its normal artifact
checks remain pending after unlock. The private procedure and generated TTS
files are ready; any future temporary settings must again be restored to their
original values and presence. The plan remains in progress.

The public source-specific evidence is recorded in
[the qualification file](../benchmarks/chatgpt-live/results/2026-10-30-now-focus-refresh-e2e.json).
The corrected build's native qualification must remain pending until its own
UI/audio rerun finishes; the earlier diagnostic does not qualify it.

## Privacy and limits

A read-only review of the new Core projection, tests and helper found generated
fixtures and no private skill, email body, account identifier or credential in
the added source. Actual recordings, backup files and authentication material
remain outside this report and the repository.

The full XCTest run is not green. The pre-correction native recording proved
several interactions but exposed a question-boundary defect; the corrected
build is installed but its native startup failed while the Mac locked.
Original QA preferences have been restored; corrected-build native interaction
qualification remains pending. Focused reruns, synthetic cloud calls and
signature/data checks do not substitute for that final qualification.

Both summaries are lossy, local recognition can miss words, and the local
conversation-moved-on heuristic is not a guarantee of semantic topic detection.
Capture, recovery, calendar/project and prior minutes/style evidence retains
its original revision labels in [the main report](macparakeet-live-validation.md)
and [the preceding focus report](macparakeet-live-focus-validation.md). None of
those earlier results substitutes for the still-pending native refresh test.
