# Live meeting preferences v1

The personal Live fork stores one local, versioned settings domain under
`AppPaths.appSupportDir/meeting-preferences`. It does not use the upstream
app's preferences, Keychain, database or cloud history.

`LiveMeetingPreferencesStore.shared` is the production actor. Its throwing
`snapshot()` returns an immutable `LiveMeetingPreferences` for a consumer to
pin before starting a task:

- `skillMarkdown`: the complete editable meeting skill.
- `skillRevision`: SHA-256 of the exact UTF-8 Markdown.
- `automaticMinutesEnabled`: enabled initially for Live identity only.
- `answerStyleEnabled`: whether Ask may use the saved style instructions/examples.
- `answerStyleInstructions` and `answerStyleExamples`: user-editable text.

The bundled default contains the complete generic rules, output template and
final quality standard, without the personal worked-example section. Its
SHA-256 is `f02e71ef1e993f138038ba21f823bfcd9419744afed88b539f6be65b1a0bf4a3`.
No real meeting excerpts are shipped in the resource.

The production store first looks for the private local
`meeting-preferences/imported-default-skill.md`. The complete original skill
can be provisioned there privately with owner-only permissions. It must never
be committed or bundled. An optional URL is injectable for isolated tests;
production defaults to this domain-scoped filename, exported as
`LiveMeetingPreferencesStore.importedDefaultFileName`. Initial settings and
Restore default use the exact UTF-8 import when present. Existing unreadable,
empty, oversized or invalid imports produce an explicit error; they never
silently fall back or overwrite existing settings. The original Downloads file
is not modified. Any private worked example illustrates format, never evidence
about another meeting. The static `LiveMeetingPreferences.defaults()` factory
uses only the generic bundled seed.

The editable style starter contains only known writing preferences: concise,
direct plain language and clear verb-first action wording. Examples start
empty. These settings do not claim or provide access to ChatGPT history or
memory. Enabled style is sent with Ask only, as writing guidance subordinate
to meeting facts, quotations, uncertainty and evidence rules. It is not meeting
context or evidence. Minutes use the meeting skill; the automatic-minutes
consumer separately sends the completed transcript and pinned skill through
the connected ChatGPT plan. Audio remains local.

## Persistence and recovery

`preferences-v1.json` contains schema version 1, the current complete version,
and up to 12 previous complete versions, newest first. A version has an opaque
UUID, save date, reason and immutable preferences. A style-only save preserves
the skill content hash. A no-op save does not create a version. Restoring an
older version creates a new current version and preserves history. The editor's
Restore default skill loads the default into its draft, preserves other draft
settings and requires Save. The store's explicit saved-default restoration
preserves all other saved settings.

Each write is atomic. Before replacing a valid current file, the store
atomically writes `preferences-v1.previous.json` with that prior valid state.
The initial seed also gets a valid backup. An advisory `preferences.lock`
serializes access across actors/processes. Nonblocking contention is an
explicit error. Editors save/restore with the UUID they loaded; conflicting
external changes are rejected while the editor retains its draft.

A corrupt, oversized, invalid or missing current file with existing backup
evidence never silently resets to defaults. The store reports an explicit
error. An explicit recovery can load a validated backup, preserving the
unreadable current file as `unreadable-preferences-<uuid>.json` before writing
a recovered current version. A newer unsupported schema cannot be edited or
downgraded by recovery. No content is logged or transmitted by this store.

Limits are 128 KiB for the skill, 8 KiB and 4,000 characters for style
instructions, and 16 KiB and 8,000 characters for examples. Oversized drafts
are rejected, never silently truncated. The complete encoded store is capped
at 4 MiB. Consumers may add defensive bounds but must send every validated
saved style whole. I/O, corrupt-state, seed-resource and conflict failures are
visible; they are not substituted with an invented successful snapshot.

## Settings

AI settings exposes an editable Markdown view and existing Markdown preview,
automatic-minutes and style switches, explicit Save/Reload, restore-default,
and previous-version Restore actions. The UI distinguishes the saved skill
revision from an unsaved draft. It explains when text is sent to ChatGPT,
the worked-example boundary, style priority and lack of history/memory access.

Focused tests: `LiveMeetingPreferencesTests` and
`LiveMeetingPreferencesViewModelTests`.
