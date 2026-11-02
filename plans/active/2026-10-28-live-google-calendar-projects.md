# Direct Google Calendar and project meeting context

Status: implemented and locally qualified; personal-fork PR remains open.

## Intended behavior

MacParakeet Live offers its own Sign in with Google button and a read-only calendar picker. Upcoming shows individual occurrences from selected personal/shared calendars. Saved private preparation and project selection follow an explicit Google event instance across title/time changes. Record carries the exact calendar event title into protected recording/transcription/recovery metadata. Generic recording matches one relevant occurrence or asks the user to choose overlapping candidates.

Project folders organize local transcripts without moving media. Live Ask combines current speech/rolling memory, this event's preparation and only the newest prior meeting in the chosen project. Select the newest row before checking readiness; never substitute an older usable meeting. Edited source and membership changes invalidate cached context and the applicable model-history range. Previous actions have unverified completion until evidence updates them.

## Invariants

- Keep the original app, capture, audio, transcript, notes, saved chat, durable artifacts and signing identity intact.
- Own Google Desktop OAuth registration, system-browser SSO, loopback callback, PKCE/state, read-only Calendar scopes, isolated Keychain tokens. User never pastes callback addresses or credentials.
- Do not reuse Codex connector sessions or browser cookies. No Google event writes.
- Shared calendar visibility does not authorize automatic recording of meetings where the signed-in user is absent.
- Current rolling summaries remain current-meeting source; the previous meeting is a separate quoted source.
- Keep upcoming calendar polling ephemeral; persist only user preparation, explicit project membership and recording-start intent.

## Implementation

- [x] Direct Google auth/service, refresh/revoke/account/cancellation guards and pagination.
- [x] Google calendar UI, selected-calendar filters, independent upcoming visibility, distinct occurrence selection.
- [x] Exact/protected calendar naming through locks, output, saved rows and recovery.
- [x] Projects, per-occurrence preparation, recording intent association and recovery binding.
- [x] Preparation/project UI and whole-folder transcript browsing/moves.
- [x] Latest-project memory, prefetch, exact excerpts, source revalidation and scope-safe chat history.
- [x] Independent source review and focused tests: 309 affected-area, 78 calendar, 75 recovery/project checks passed.
- [x] Once-per-task full regression gate: 8,417 XCTest tests, 35 skipped, zero failures; 30 Swift Testing tests passed.
- [x] Supported persistent-signed Release build and installation after verified local DB backup.
- [x] Actual app Google sign-in and primary/shared calendar reads; native preparation/project UI inspection; existing permissions and completed ChatGPT connection check.
- [x] Commit/push final qualification and update the existing personal-fork PR.

## Runtime setup

The dedicated Google project and Desktop OAuth client were created; the user completed account verification and required Google policy/API activation. Initial installed qualification used `14851bd6a0c6`; the current signed Release is `a0f4b3c6ce15`. Its own Google connection reads the requested calendars and loads upcoming occurrences after restart without manual Refresh. The app-owned installed-client registration is stored privately outside the repository. Do not publish that file or any user calendar content. The configured Workspace Internal audience covers the tested work account; external accounts are not qualified.

## Qualification limits

The initial quiet UI inspection was followed by actual calendar-selected recordings, private synthetic preparation, project assignment and completed cloud answers. Native replay verified latest-prior selection and current corrections; interrupted recovery and normal Stop preserved exact title/context/project, notes, completed chat and validated audio/artifacts. Test preparation was restored to blank/no project. These short transcripts fit raw context; the accelerated two-hour writer case is not a native multi-hour hardware soak. Earlier audio/hotkey and rolling-memory measurements retain their source labels, and no general project-context latency distribution is claimed. Full evidence is in `docs/macparakeet-live-validation.md`.
