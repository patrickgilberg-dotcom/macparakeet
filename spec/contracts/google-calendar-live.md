# Google Calendar and project context in MacParakeet Live

## User workflow

Live offers **Sign in with Google** in the app. It opens the default system
browser, receives Google's callback locally, and returns to the app. The user
does not add an Apple Calendar account, grant native Calendar/TCC access, paste
a callback, enter a redirect URI, or configure an OAuth client in the product UI.
The app's Google connection is independent of Codex connectors and the ChatGPT
connection. Google supplies calendar data; the existing approved ChatGPT plan
connection supplies optional summaries and answers.

Upcoming shows individual events from included calendars, including shared
calendars such as Ajay's. An event can have privately saved preparation and a
project. Explicitly recording a selected shared event is allowed. Merely showing
a shared calendar does not authorize automatic recording of its owner's calls.

## Owned desktop OAuth registration

`GoogleCalendarAuth` uses this app's own registered **Desktop app** OAuth client
in a dedicated Google Cloud project with Calendar API access enabled. Client
registration is developer/deployment configuration, never an end-user form.
Supported configuration is:

- Bundle keys `GoogleCalendarOAuthClientID` and optional
  `GoogleCalendarOAuthClientSecret`.
- Developer environment overrides `MACPARAKEET_GOOGLE_CALENDAR_CLIENT_ID` and
  optional `MACPARAKEET_GOOGLE_CALENDAR_CLIENT_SECRET`.
- Google's downloaded `{"installed": {...}}` client JSON at
  `~/Library/Application Support/MacParakeet-Live/GoogleCalendar/client.json`,
  optionally overridden by developer environment path
  `MACPARAKEET_GOOGLE_CALENDAR_CLIENT_CONFIG`.

The installed client JSON is local and untracked. Desktop clients cannot keep a
client secret confidential; any supplied desktop secret is registration
metadata, not a substitute for user consent. Missing or invalid registration is
a typed visible setup error. The app never borrows a connector token, a browser
cookie, or another application's client registration.

Before opening the browser, the app binds an ephemeral port on `127.0.0.1`.
The exact redirect is `http://127.0.0.1:<port>/`. Each attempt uses cryptographic
state and PKCE S256. Callback method, host, port, path, state and duplicate
parameters are checked. Authorization code and error cannot coexist. There is
no manual or custom-URI fallback. Account identity comes from Google's
authenticated HTTPS UserInfo endpoint; unverified ID-token claims are not used.

The requested scopes are only `openid`, `email`,
`https://www.googleapis.com/auth/calendar.calendarlist.readonly` and
`https://www.googleapis.com/auth/calendar.events.readonly`. Offline access is
requested to refresh this read connection. No calendar write scope is requested.

Tokens are saved atomically in the isolated Keychain service
`com.patrickgilberg.macparakeet-live.google-calendar`. Normal reads do not show
Keychain UI; explicit Unlock can request macOS consent. A blocked read remains
distinguishable from an absent connection. Concurrent expired-token callers
share one refresh, omitted refresh tokens retain the prior renewable token,
and returned scopes must still cover both read operations. Temporary failures
preserve credentials; terminal `invalid_grant` removes the local connection.

Disconnect invalidates local generations and removes local credentials before
attempting Google's token revocation. Revocation failure is visible. A pending
callback or refresh cannot reconnect after Disconnect. A new sign-in must not
overlap an unfinished revocation or older sign-in cleanup: Google revocation
can remove the user's entire grant across clients in the same Google project.
This is another reason to use a dedicated project. Tokens, authorization URLs,
account identifiers and calendar contents do not belong in diagnostic logs.

## Calendar reads and participation

`GoogleCalendarService` conforms to `CalendarServicing`. Its permission status
reflects the app's own Google connection, not native Calendar/TCC. Polling never
opens sign-in. Calendar discovery uses paginated `calendarList.list`; event
reads use paginated `events.list` for included calendars with `singleEvents=true`,
`orderBy=startTime` and a bounded date range. Cancellation, account changes and
calendar-selection changes discard stale results. Errors cannot masquerade as
a successful partial page set. Calendar IDs are encoded as single path segments.

The event list preserves the exact supplied title. Provider metadata retains the
raw calendar ID, event/instance ID, recurring series ID, original occurrence
start and iCalendar UID. Display/list IDs are namespaced by provider and calendar;
preparation keys use the explicit raw Google calendar ID and event/instance ID.
Titles and scheduled times are not preparation identity. Separate recurring
instances do not silently share a draft.

Automatic recording considers a Google event a user meeting only when it is on
the primary calendar, the connected email is the organizer, or the connected
email appears among attendees. Email comparison is case insensitive. Google's
`attendees.self` refers to the owner of that calendar copy; on shared calendars it
does not prove the connected user attends. It is a fallback only on the primary
calendar. Shared-only events remain visible, with no fabricated RSVP status,
while automatic recording excludes them. Existing declined-event and other
recording policy filters still apply.

## Private preparation and projects

Calendar polling remains in memory; it is not mirrored into a queryable SQLite
event cache. `MeetingPreparation` is an explicit user-authored draft, stored in
the private Live database with its event identity, context, selected project and
title/schedule snapshot. Saving a draft does not modify Google Calendar. A later
calendar edit or deletion does not silently erase the user's preparation.

`MeetingProject` is a virtual Library folder. Membership changes do not move or
delete transcript/audio files. Removing a project unfiles its transcripts.
When recording begins, `RecordingMeetingAssociation` freezes the chosen event,
preparation and project against the native recording UUID. Finalization binds
that association to the correct meeting row atomically. A later folder move is
not undone by repeated finalization. The calendar title remains protected from
automatic AI renaming; explicit user renames remain available. Filesystem-safe
filenames do not change the stored event title.

## Live answer grounding

An answer combines the fresh current transcript and its current-meeting rolling
memory, notes/session preparation, the frozen event preparation, and at most
**one** previous meeting from the selected project. The three-minute current
meeting summary never absorbs project history or event drafts into its source.
Prior-project reference memory is separate and explicitly labeled historical.

The repository selects the actual latest eligible project meeting before the
current recording's start, ordered by creation time and stable ID, excluding the
current recording/row and split derivatives. It selects the row **before**
checking transcription readiness. If that row is processing, failed, cancelled
or empty, the answer reports its unavailable state. It never silently substitutes
an older completed meeting. No project means no automatic prior-meeting source.

`LiveProjectMeetingMemory` can prebuild a brief when project context is attached,
using the same pinned `LiveAnswerStreamSession` as Live Ask. Foreground Ask
cancels and awaits prefetch, re-reads the selected source, and retries necessary
preparation before answering. Ready prior transcripts are processed in full
through bounded semantic-summary chunks. The answer receives up to 8,000 summary
characters, 6,000 exact question-relevant excerpt characters, a 3,000-character
raw prior tail and 4,000 prior-note characters, with project/title/date/status
provenance. This is selective, lossy context, not guaranteed verbatim recall.

The prior-source scope includes project and source identity, readiness, effective
transcript hash, speaker/correction revision, metadata and notes. Edits, deletion,
membership changes or a different selected latest row invalidate the cached
brief and model-facing conversation scope. Old UI history may remain visible,
but is omitted from new model input after a source-scope change. Source identity
is checked before dispatch and before accepting the completed answer. Provider
account/model/effort/transport/policy identity is also pinned and validated; normal
token refresh does not authorize changing that identity mid-build.

Historical actions are previously recorded actions with unverified current
completion status. Absence from the current discussion or a lossy summary does
not establish that an action was missed, overdue, completed or cancelled.
Current explicit corrections take precedence; unresolved contradictions remain
visible. Quoted calendar/preparation/transcript content cannot become model
instructions. No tools, broader Library search, paid fallback or new AI
authorization is introduced. See [Live answers](live-answer.md) and
[ChatGPT plan usage](chatgpt-plan-usage.md).

## Qualification

Initial qualification of Release `14851bd6a0c6` completed native Google browser sign-in
and read upcoming events from the primary and Ajay shared calendars. Native
preparation/project controls were inspected without saving test user data.
The dedicated deployment uses a Workspace Internal audience; external-account
eligibility is not qualified. The supported signed build/installation, focused
integration tests and once-per-task full regression gate passed: 8,417 XCTest
tests with 35 skipped and zero failures, plus 30 Swift Testing tests. See
[qualification evidence](../../docs/macparakeet-live-validation.md).

An additional 411.277-second native recording qualified exact calendar naming,
saved event context, latest-project selection and current spoken corrections
through three completed cloud answers. Two scheduled context refreshes and
normal artifact saving were observed. Its short synthetic transcript fit raw
context; this is not long-meeting semantic or multi-hour hardware qualification.
An interrupted native recording exposed the previous chat-save gap. Source
`9447f78bcb2e` then passed native interruption recovery and normal Stop with exact
completed chat, notes, title/project/context and validated audio/artifacts.
Final installed `a0f4b3c6ce15` adds the calendar-startup selection repair, with
63 focused checks and automatic native event loading after restart. Selection
binds after unfiltered discovery; account/cancellation checks and selection
invalidation during event reads remain enforced. See the linked qualification
evidence for measured source boundaries and limits. No general latency
distribution or real-meeting accuracy guarantee is established.

Relevant focused areas are `GoogleCalendarTests`, `CalendarRecordingIdentityTests`,
`MeetingProjectPreparationRepositoryTests` and `LiveProjectMeetingMemoryTests`,
plus planner/recording/Live Ask integration coverage.

Primary contracts: [Google desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app),
[OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect),
[Calendar list](https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list),
[Events list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list),
and [event resources](https://developers.google.com/workspace/calendar/api/v3/reference/events).
