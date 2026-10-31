# Personal-fork evidence board and automatic preparation

This contract extends [live answers](live-answer.md) and [Google/project context](google-calendar-live.md).

## Sources and boundaries

Generated items and briefs never replace user-authored `userNotes` or `MeetingPreparation.context`. The board reads available recognized current speech and current notes, plus at most the one latest prior meeting selected by `MeetingProjectRepository`. Prep uses only that latest prior transcript and its full saved notes. Unready latest transcription does not permit an older substitute; available notes remain separately attributed. Core audio, transcripts and finalization are unchanged.

Every source document has an identity, kind and captured text. All nonblank source characters pass through bounded extraction chunks; long notes are not reduced to their first few thousand characters. Extracted items are lossy, bounded suggestions, not guaranteed exhaustive recall. Coverage and filtered/omitted counts remain visible. Unsupported owners/dates and nonliteral quotes are discarded. User notes never establish spoken acceptance or completion. Proposals and approval conditions remain distinct from confirmed commitments.

Clickable quotations open the exact captured source, with its title, provenance and snapshot time. The quote is validated again as exact UTF8 before display. It is never mapped fuzzily to a corrected live line. Previous-meeting actions remain completion-unverified unless later explicit transcript evidence establishes resolution. Silence, notes and omission cannot establish completion.

## Scheduling and priority

The live board follows the existing 180-second background memory lane and also has an explicit Refresh button. Ask cancels and awaits the entire lane, including extraction. No new words automatically send a question, and Ask does not run the board extractor. Fully completed, validated extraction chunks and reconciliation responses can be cached across preemption, with bounded account/source/payload keys. Incomplete requests never establish cached coverage, and partial passes never publish a completed board. The previous valid board can remain visible as a dated snapshot after an update fails. Changed transcript/notes are disclosed; a changed or deleted project scope invalidates prior carryover. Append-only speech can publish an honest as-of snapshot; corrections or note edits during processing cannot publish it as current. Explicit later resolution or retraction needs its own chronological raw-transcript quotation; notes and silence cannot close or reopen items.

Automatic prep polls every 60 seconds while Live is running and the Mac is awake. It becomes due in the 15 minutes before an upcoming, nondeclined, non-all-day Google occurrence that has an explicitly saved project assignment. Unselected shared-calendar events never send their contents to ChatGPT. Explicit assignment permits an occurrence on a shared calendar such as Ajay's. Excluded calendars stay excluded. This scheduler is independent of recording auto-start; it never starts or stops a recording.

Prep yields to live answers, summaries, board refresh, project prefetch and minutes. Capture alone permits preparation for a back-to-back meeting. Starting a recording and starting the current meeting's inference cancel and await active prep. A missed window while asleep or busy is not a guarantee of on-time generation. Prepare now offers explicit generation before recording. The automatic toggle is persisted and can cancel work.

## Persistence and stale-source protection

Generated prep is separate atomic JSON under the isolated app-support `generated-meeting-preparation` directory. Hashed occurrence keys avoid path interpretation and title disclosure in filenames. Directories/files use private permissions; each artifact is limited to 16 MiB. There is no persisted calendar inventory. Original notes, manual preparation, user database and meeting audio are not deleted by this feature.

An explicit full source-meeting deletion removes matching generated copies through the existing ordered app/CLI/bulk deletion boundary. A local cross-process lock and durable small UUID cleanup intent prevent late writes from restoring deleted text. Normal failed/no-op source deletion preserves preparation; failed derived cleanup is retried on later store access and never becomes usable again. Unrelated artifacts and audio-only deletion are unchanged. The legacy synchronous deletion API is preserved; there is no fire-and-forget cleanup. Derived prep load/save remain actor-isolated off the UI actor.

Reuse and publication validate occurrence, project, latest source identity, corrected transcript, full notes, manual-context hash and pinned ChatGPT provider identity. Source/account changes cannot silently reuse an old brief. Failed/cancelled generation never creates a valid replacement. A ready brief is loaded without inference into a small collapsible live card and a separately quoted historical Ask block. Current question, complete immediate speech, recent three-minute summary and general current-meeting memory keep their existing priority. Preparation does not import ChatGPT conversation history or account memories.

## Verification

Focused tests cover full-source note coverage, exact quotes, unsupported ownership/dates, separate note provenance, latest-only selection, the exact 15-minute window, unselected/shared occurrences, source/account/manual-context changes, cancellation, atomic storage and foreground Ask preemption. Validation results and native acceptance limits belong in `docs/macparakeet-live-board-preparation-validation.md`.
