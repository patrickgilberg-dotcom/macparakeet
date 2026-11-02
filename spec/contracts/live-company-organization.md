# Companies and projects in the personal Live fork

## User behavior

Live organizes upcoming meetings under companies before capture. The company
is suggested automatically; a project within that company is optional. The user
can record immediately, select/create a project during the call, or organize a
saved meeting later. Names, domains and selections are editable local data.

## Discovery and matching

An app-lifetime local sweep reads the next thirty days from all included Google
calendars, including shared calendars, and repeats periodically while Live is
running. It uses the existing paginated, account/selection-validated provider.
All-day, declined and excluded-calendar events remain excluded. Discovery does
not start recording, expand calendar permissions, create calendar events or
invoke an LLM. A failed/partial read is not reported as a completed sweep.

Eligible signals are nondeclined people with valid business email domains,
including the organizer. Rooms, resources, service calendars and common personal
mail providers do not create companies. The connected account's own business
domain is distinguished from external customer domains. Domain normalization is
case-insensitive, validated and exact; lookalike suffixes are not matches.

An eligible external organizer provides the company's strongest signal.
Otherwise one distinct external company among attendees can resolve the event.
Several plausible external companies remain a visible choice rather than a
majority-vote guess. When external business signals are absent, an unambiguous
whole-word match to a known company name/domain label may organize an internal
follow-up. Unknown companies are not invented from arbitrary title words.

Discovery creates missing company records using the business domain as an
editable display label; this is not verification of a legal company name.
Creation is idempotent and transactional. Existing/archived domain records are
not duplicated or silently unarchived. Customer-specific names/rules are not
bundled in source or seeded by migration. A saved occurrence organization always
wins, including an explicit empty choice. The nullable company-choice intent
flag distinguishes new explicit choices from pre-company context-only drafts.
Those older drafts may infer a company while retaining their agenda and identity;
legacy project selections remain authoritative.

## Persistence and context boundaries

Company records contain a local identity, editable name, normalized domains and
ordinary lifecycle metadata. No occurrence IDs, event bodies or attendee lists
are saved by the sweep. Companies and projects are distinct tables. A project
can belong to one company; legacy projects remain valid with no company.
Company membership is separate so a recording can have a company and no project.

Selecting a company/project changes only organizational membership. Source
transcripts, notes, audio, paths and exact calendar titles are preserved.
Selecting a project with a company sets compatible company membership;
clearing a project preserves the company. A company change clears incompatible
project membership. Recording associations persist company/project intent under
the existing recording UUID and support explicit organization changes without
rewriting frozen calendar context. Final binding remains atomic/idempotent and
does not undo a later saved-meeting move.

Only the explicitly selected project supplies latest-prior-meeting context and
fifteen-minute generated preparation. Company discovery never chooses a project
or adds a company-wide meeting history to Ask. An explicit live project change
clears stale project/derived context before the new scope is used; current speech,
notes, summaries and answer-style priority retain their existing boundaries.

Calendar attendees and company domains are not added to telemetry or provider
prompts by this feature. Original app data, signing identity and permissions are
unchanged. The feature is specific to the personal Live fork.
