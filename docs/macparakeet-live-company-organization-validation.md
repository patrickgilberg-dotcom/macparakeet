# Company discovery and optional projects in Live

## Behavior and scope

Companies and projects are separate. A local background sweep checks the next
thirty days on included Google calendars, including shared calendars, and
creates missing company folders from eligible business email domains. Unknown
names start as editable domain labels. Known-company title matching supports
internal follow-ups; conflicting signals remain a choice. Customer names/rules
are not bundled in source. The sweep does not invoke ChatGPT, write to Google
Calendar or create an event inventory.

The user can record with only a company and choose/create a project during the
call or organize a saved meeting afterward. Company and project dropdowns replace
the earlier assumption that the customer name was itself a project. Only the
chosen project supplies its latest previous meeting and saved notes to Ask;
company discovery never substitutes company-wide history. Exact calendar titles,
authored event context, current speech, notes, summaries and the personal answer
style retain their existing boundaries.

See [the organization contract](../spec/contracts/live-company-organization.md)
and [calendar contract](../spec/contracts/google-calendar-live.md).

## Completed focused verification

The final focused run executed **335 tests, one skipped, zero failures**, in
**25.195s**, following a **32.17s** incremental build. It covers company discovery,
matching, database migration, membership, planner/recording controls, live
organization changes, Ask priority, Google Calendar occurrence/title handling,
current 20–30-second/three-minute focus, and existing transcript chat behavior.
The skipped case is an explicitly opt-in native company/project control check;
it is not counted as completed interactive acceptance here.

Core coverage includes 28 matcher and 22 repository/migration cases. A unique
external organizer can resolve the company; public mail, rooms/resources,
declined attendees, own-team domains, lookalike suffixes and unknown title-only
companies do not create a false customer. Multiple plausible companies remain
unresolved. Multipart domain suffixes cannot become generic title aliases.

Migration v0.53 preserves all source transcription fields and existing unowned
projects. Company-only membership is separate. Project names can repeat across
companies. An old context-only preparation is distinguished from a new explicit
No company choice, retaining its agenda and identity. Organization moves are
atomic, reject mismatched/archived scopes and preserve exact event context.
Repeated finalization does not undo a later saved-meeting move.

Concurrency checks cover company/account/calendar changes during a sweep,
cancellation between committed domain writes, project creation completing after
a newer company selection, a new save queued while Stop is already waiting,
and End during project creation. End freezes new intents, stops audio first,
then settles admitted creation and ordered organization saves before binding.
Ask/Update/regeneration make no request while organization is saving; old-scope
stream output cannot publish afterward. Archiving only the parent company also
invalidates preparation and live previous-project context.

The first focused attempt exposed harness assumptions: a generic `Customer`
title fixture correctly did not match, SQLite date precision changed a whole
object comparison, the standalone hosting view needed the real panel's width
constraint, and three older startup tests awaited only the replaced permission
task. Their fixtures/await boundaries were corrected without weakening expected
meeting titles or snapshots. The earlier startup test's unchecked array access
also crashed after its failed assertion; the resulting checked access preserves
failure reporting. Subsequent focused runs completed cleanly.

Independent reviews identified and closed stale company-selection overwrite,
indistinguishable same-named projects, archived-parent context access,
between-write discovery scope changes and pending-organization finalization
findings. The final review converged with no remaining must-fix finding.
Changed Swift lines pass strict swift-format and whitespace checks. The complete
DatabaseManager file retains unrelated pre-existing formatting findings.
Local no-mistakes and Greptile executables are unavailable.

## Full-suite gate

The task's single full-suite attempt completed **8,707 XCTest cases, 38 skipped,
zero failures**, in **479.825s**. The separate Swift Testing runner passed
**30 tests in three suites**. The command explicitly unset the temporary debug
app-state override; the normal-path run therefore does not carry the isolated
path-assumption failures from the earlier board/preparation task. The full
suite was not repeated.

## Remaining installation checks

The signed build/install, genuine thirty-day calendar sweep and final quiet
native acceptance are pending. Their completed results
will replace this paragraph before the task is closed. No new microphone or
system-audio recording is part of this quiet acceptance. This task does not
establish a multi-hour recording guarantee or requalify every original-app
feature.

Before changes, a consistent private SQLite backup was made. The 21 canonical
meetings, their source-field fingerprint, saved style/preferences fingerprint
and original app executable fingerprint were recorded privately. A signed copy
of the preceding installed Live build is retained as a rollback artifact.
Private calendar identities, event bodies, source speech and settings remain
outside this report and the repository.
