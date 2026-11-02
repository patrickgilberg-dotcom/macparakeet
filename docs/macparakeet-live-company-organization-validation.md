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

The main integrated focused run executed **335 tests, one skipped, zero failures**, in
**25.195s**, following a **32.17s** incremental build. It covers company discovery,
matching, database migration, membership, planner/recording controls, live
organization changes, Ask priority, Google Calendar occurrence/title handling,
current 20–30-second/three-minute focus, and existing transcript chat behavior.
The skipped case is an explicitly opt-in native company/project control check;
its separate completed interaction result is recorded below.

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
suite was not repeated. This full run predates the later menu-layout and
calendar-sweep hardening changes; their focused/native/build checks are recorded
separately and do not retroactively change that source qualification.

## Native interaction and installed-calendar acceptance

The production controls were checked at the real panel width. A cramped single
row clipped the company control; the final view uses two constrained menu rows
and keeps long labels accessible. After that view change, **77 focused cases,
one opt-in skip, zero failures** passed in **15.907s**. The separate native
interaction case then passed **one case, zero skips/failures**, in **62.412s**:
create a project in the first company, switch company (clearing that project),
choose the second company's project, and verify the callback and persisted scope.
The private native host uses synthetic in-memory data and no capture. Early
native attempts exposed a blocked asynchronous test-host loop and menu tracking
mode; those test-only issues were corrected before the completed result.

Signed Release `03ee501ee3bd`, built `2026-11-02T17:58:29Z`, was installed through
the supported scripts. The real thirty-day sweep checked **320 upcoming entries**
and created **eight domain folders**. A later scan checked 319 as time advanced.
Inspection surfaced a scheduling delivery sender and an own-team domain alias;
these prompted the final hardening below rather than being accepted as correct
client classifications. Requested familiar company labels were applied privately.

The final hardening excludes precise scheduling-delivery mailboxes while keeping
real vendor employees eligible. Own-team aliases come only from one company
configured for the exact signed-in domain, including archived own-team metadata;
missing, malformed or ambiguous ownership narrows to the signed-in domain.
Account, excluded calendars and aliases define the sweep fingerprint. Archive
and Restore change availability without deleting projects or source data.

After those changes, **88 focused cases, one opt-in skip, zero failures** passed
in **3.414s**. The initial hardening run had four assertion failures in two new
fixtures: a generic company title correctly did not match, and pre-persistence
objects carried dates beyond SQLite's saved precision. Concrete title and
persisted snapshot baselines fixed those fixtures while retaining the matching
policy and full-object preservation assertions. Review also closed malformed
competing alias ownership before the final run. Strict formatting and whitespace
checks pass; independent review found no remaining must-fix finding.

Final signed Release **`571fa9bc26bc`**, built **`2026-11-02T18:17:48Z`**, is
installed at the separate Live application path and running on Meetings. Deep,
strict signature verification passed for both installed apps, with Live's stable
Apple Development identity and bundle ID retained. No new permission or account
sign-in was needed.

The final genuine sweep checked **319 upcoming entries**, matching **six external
company folders with zero additions** on repeat. The configured own-team folder
is retained separately, giving seven active company records. The one initial
scheduling-service false folder was archived through the production UI. Restore
made it available again, a second archive hid it, and another sweep neither
recreated nor restored it. On-screen upcoming captions retained familiar company
labels, title-only follow-up matching, exact event names and optional projects.
The final screenshot inspection found no clipping in the company/project browse
controls. No customer identities or event inventory are published here. No new microphone or system-audio
recording is part of this quiet acceptance. This task does not
establish a multi-hour recording guarantee or requalify every original-app
feature.

Before changes, a consistent private SQLite backup was made. The final
read-only comparison found all **21 transcription rows equal in every existing
column**. The existing project, authored preparation, six project memberships and
eight recording associations also match the backup in every pre-existing column.
All **21 recording paths and 21 meeting-artifact folders exist**. Database
integrity is `ok`, with zero foreign-key violations. The saved style/preferences
fingerprint and original app executable fingerprint are unchanged. A signed copy
of the preceding installed Live build and the pre-migration database backup are
retained together as rollback evidence; app-only downgrade compatibility is not
claimed.
Private calendar identities, event bodies, source speech and settings remain
outside this report and the repository.
