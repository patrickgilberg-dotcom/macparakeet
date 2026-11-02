# Company discovery and separate projects in Live

User intent: automatically sweep upcoming calendars and organize meetings under
the right company, creating missing companies. Companies are not projects; the
user chooses a project when starting, during recording or afterward.

Context zone: the existing personal `feat/macparakeet-live` fork and PR. A
thirty-day local business-domain sweep covers all included calendars, including
Ajay's, without inference or new permissions. Known-company titles can resolve
internal follow-ups. Unknown business-domain companies receive editable domain
labels. Projects are never guessed. Scope is defined by
`spec/contracts/live-company-organization.md`.

Must preserve: exact Google title/occurrence identity, saved choices and authored
context, latest-project-only historical evidence, complete notes, Ask priority,
capture/recovery, stable signing, original app, style preferences, all canonical
meeting rows and artifacts. There is no event inventory or attendee telemetry.

- [x] Inspect live source, contracts and primary/shared-calendar examples.
- [x] Back up the database; record source, preferences and original-app fingerprints privately.
- [x] Add companies, separate membership and additive project/association fields with focused migration tests.
- [x] Implement business-domain discovery, idempotent company creation and deterministic ambiguity handling.
- [x] Add company/project dropdowns before/during/after recording and explicit organization updates.
- [x] Wire the thirty-day sweep and preserve project-only preparation/context.
- [x] Update contracts, schema and user-facing validation notes.
- [x] Run focused tests, independent review and one final full-suite attempt (335 focused; 8,707 full, zero failures).
- [x] Build/sign/install using supported Live scripts; privately apply the requested known company labels.
- [x] Verify the real full calendar sweep, UI, saved settings/data and original-app preservation without recording.

Verification covers synthetic database/resolver/organization/flow tests and quiet
native acceptance with real calendar reads. It does not claim a new multi-hour
audio test. Private calendar identities/bodies, user data and customer examples
remain outside published artifacts. No upstream-site publication or merge is
part of this personal-fork update.

Completed on `feat/macparakeet-live`. Signed source `571fa9bc26bc`, built
`2026-11-02T18:17:48Z`, is installed. The final repeat sweep checked 319 upcoming
entries, six external company matches and zero additions. Native company/project
creation and switching, plus installed Archive/Restore, passed. All 21 baseline
transcriptions and existing organizational rows remain unchanged; signatures,
recording paths, saved preferences and the original app passed preservation
checks. See `docs/macparakeet-live-company-organization-validation.md` for source
qualifications, the initial scheduling-service correction and verification limits.
