# Immediate meeting focus and explicit answer refresh

Status: in progress.

## Scope

Add a fast immediate raw-speech layer around the latest 30 seconds, extending
selection to preserve complete questions or speaker turns. Retain the completed
three-minute focus summary, cumulative general memory and separately attributed
calendar/project/style context. Give a live answer a visible stable anchor and
capture time, and offer Update answer when meaningful new discussion or a
correction supersedes that snapshot.

## Invariants

- The new immediate projection and freshness comparison are local. They add no
  model-summary call to explicit Ask or Update answer.
- Complete relevant questions remain available beyond a strict 30-second cutoff.
  Raw Now source extends to a speaker/pause boundary, ignoring recognition
  punctuation inside an unbroken utterance. Silence alone cannot make a
  captured answer stale.
- Transcript, immediate source, recent source and notes are captured together
  before asynchronous preference or context preparation.
- The priority is explicit current question, immediate raw focus, completed
  three-minute focus, then general/background context. New explicit corrections
  and existing approval conditions remain authoritative.
- Completed answers stay readable. Refresh is explicit and cancels an active
  old request before preparing a fresh snapshot. Cancelled partial output never
  becomes a successful assistant/history turn, and late output cannot write
  into a newer answer.
- Capture, recovery, final minutes, saved preferences, source-gap warnings,
  account/model pinning and complete available-source coverage remain intact.
- UI time labels describe context capture, not an acoustic speech boundary.

## Work

- [x] Add and verify the immediate-source and complete-question projection.
- [x] Capture immediate/recent/full context atomically and prioritize it in Ask.
- [x] Detect meaningful new discussion/corrections locally and scope state to
  the active answer and recording.
- [x] Show question/turn anchor, capture time and explicit Update answer action.
  The action remains available during and after generation; VM state gates it.
- [x] Update the governing context contract and preserve prior qualification labels.
- [x] Add targeted boundary, freshness, cancellation, snapshot and source-priority
  tests, including during an in-flight answer.
- [x] Complete independent review and focused source-specific test gates;
  preserve the failed full-suite result as an unresolved qualification limit.
- [x] Qualify the genuine synthetic cloud flow through the production ViewModel
  and explicit Update action.
- [x] Build and install the original feature Release `1136349991ae`; verify its
  source receipt, signature and retained 17-meeting baseline before native QA.
- [x] Run a native diagnostic of the real summary timer and explicit Update flow;
  retain the failed long-question boundary case and its artifacts.
- [x] Correct recognition-punctuation truncation in `fb7342b6e821` and pass the
  expanded 193-test focused gate.
- [x] Install the corrected signed Release `fb7342b6e821`; verify its strict
  signature and retention of the 17 baseline meetings plus one diagnostic row.
- [x] Restore original QA preference values and their presence after the
  corrected-build native startup failed while the Mac locked.
- [x] Finish the corrected-source signed helper's new cloud run with five
  terminal requests and zero foreground summary calls on either answer.
- [ ] Rerun native complete-question capture/Update on the corrected build after
  unlock, verify normal artifacts and restore any new temporary preferences.

## Verification

Partial qualification is recorded below and in
[the new validation report](../../docs/macparakeet-live-now-validation.md).
Earlier focus, calendar/project, recovery and minutes/style evidence retains
its original source labels and does not qualify this new native refresh
interaction. Run the full suite at most once for this task. Report functional,
timing, native capture and synthetic qualification separately; do not turn a
simulated timeline into a hardware recording or latency guarantee.

## Verification progress

- Qualification spans October 30–31, 2026 in Edmonton. Installed correction
  source `fb7342b6e821` was built at `2026-10-31T03:54:23Z` (October 30 locally)
  and passed strict signature verification. Original feature source
  `1136349991ae` was built at `2026-10-31T00:56:46Z` and installed with a
  matching supported-installer receipt.
- The first build exhausted temporary disk space during debug-symbol generation,
  before tests, with no Swift source error. The focused gate was rebuilt using
  Debug `-debug-info-format none` with assertions retained: **189 passed**,
  zero failures, in **9.749 seconds** at `1136349991ae`. The correction at
  `fb7342b6e821` added four boundary cases and passed **193 tests**, zero
  failures, in **10.007 seconds**. These are successive focused gates.
- At `1136349991ae`, production-ViewModel `freshnesscheck` exited successfully:
  **three terminal summary calls**, **two terminal answers**, and **zero
  foreground summary calls** for either Ask. A 32.25-second complete question retained its beginning
  beyond the strict 30-second cutoff. Now, three-minute and general context
  remained separate.
- The new-question notice did not infer: answer-call counts were one before and
  after notification. Explicit Update answered the new route-owner question,
  retained the corrected synthetic ceiling, cleared the current moved-on flag
  and kept the earlier completed answer readable.
- One initial-answer lexical approval flag remains false because its markers
  missed “isn’t approved.” Manual review confirms the actual answer denied launch
  approval and preserved the security condition. The flag is not rewritten as
  a pass. Helper timings overlap build/test activity and are not native Release
  latency evidence.
- The signed helper rebuilt at `fb7342b6e821` completed a fresh run with exit 0:
  **three terminal summaries and two terminal answers**, with **zero foreground
  summary calls** on either answer. The 32.25-second generated question,
  no-inference notice (answer counts **1 → 1**), fresh Update anchor, retained
  old answer and both summary layers passed. The same lexical approval marker
  remains false; manual review confirms “isn’t approved” denied launch approval.
  Rounded Ask timings were **841 / 1,578 / 1,907 ms** to first text / first
  sentence / completion; Update was **1,221 / 1,550 / 1,773 ms**. These are Debug
  helper timings with numeric fixtures, not native rendering or ASR evidence.
- At `1136349991ae`, the ONE full-suite command finished with **exit 1**. Existing
  `TransformsCommandTests.testRunRecordsTransformHistory` timed out with a
  300-second configured limit and **450.661-second** observed wall time. The
  XCTest host then aborted with signal 6 and `NSFileHandleOperationException`
  for a closed descriptor in `LocalCLIExecutor.writePromptData`. There is no
  All Tests completion summary; do not claim every XCTest case ran or passed.
  The separate Swift Testing run passed **30 tests**.
- Stack inspection showed 64 blocked AppKit/NSAnimation workers and long
  suspension/resource periods. The existing cleaned-mic test passed after
  **2,085.208 seconds**, and its class passed. These observations do not prove
  the sole cause of the later failure.
- At `1136349991ae`, a fresh focused
  `LocalCLIExecutorTests|TransformsCommandTests` rerun passed
  **90 tests** in **17.950 seconds**, including the prior transform-history
  case in **0.321 seconds**. This does not erase the full failure. No legacy
  runner code was changed; the direct ChatGPT path does not use that route.
  Its I/O ownership refactor remains separate. The full suite was not repeated.
- Before native QA at `1136349991ae`, strict/deep installed-signature
  verification passed. The private backup passed its integrity check; all
  **17 baseline meeting IDs** were retained, preferences and the original app
  hash were unchanged, and no recording lock remained. This predates the new
  diagnostic recording and temporary QA preferences.
- The unlocked native `1136349991ae` diagnostic recorded **5:34** of synthetic
  system audio, with zero microphone bytes, no calendar event and no project.
  A real 180-second tick produced both summaries. Ask took **1.9211 s** to first
  text, **2.1631 s** to first sentence and **3.1987 s** to completion; Update took
  **1.9291 / 2.1846 / 2.6161 s**, respectively. These are invocation timings for
  that pre-correction Release, not an acoustic-end latency guarantee.
- Forty-three seconds of silence did not mark the answer stale. New question B
  showed the notice without inference; the actual Update button answered B
  correctly and retained the previous completed answer. Normal Stop saved
  decodable audio, transcript and chat with one recovery receipt.
- The same diagnostic exposed internal recognition periods truncating a long
  question's early clause: Now/anchor began at 3:33 rather than 3:13. The saved
  **QA Now Focus Boundary Check** row is diagnostic, not final qualification.
  `fb7342b6e821` extends raw source to a speaker-or-pause boundary inferred
  from word timings and coalesces the anchor lead-in, with bounded lexical
  rules rather than guaranteed semantic parsing.
- The installed `fb7342b6e821` native attempt started at
  `2026-10-31T03:54:49Z`, and the Mac locked during startup. At `03:55:03Z`,
  metadata reported `system_audio_stream_start_failed`
  (`MeetingAudioError.systemAudioCaptureFailed`, code 2). No recording was
  persisted and no active lock remained. The lock and error were observed
  together; the lock is not established as the sole cause.
- Host tools paused overnight and resumed at `2026-10-31T16:36Z` (October 31
  locally). Unlock is pending. Original audio-source and calendar-exclusion
  preferences and their exact presence are restored from the snapshot; the
  other three checked QA keys were unchanged. URL control stays disabled.
  All 17 baseline meetings and the one diagnostic remain (**18 rows**), and
  the app was ordinarily quit with no active recording.
- Corrected-build native interaction qualification remains pending. The private
  procedure and TTS clips are ready; any new temporary settings must be
  restored again after the unlocked rerun. The plan remains in progress.
