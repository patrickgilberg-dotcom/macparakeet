# Automatic meeting minutes in MacParakeet Live

The personal Live fork generates minutes through its existing authorized
ChatGPT-plan connection after a meeting's final local transcript is saved. This
path is separate from optional upstream analysis providers. It never uses an API
key, paid fallback, browser cookies or ChatGPT conversation history. Audio stays
local; final recognized transcript text is sent for the requested generation.

When the optional legacy analysis route is absent, Live skips its separate
auto-prompts and knowledge-card completion rather than reporting a missing
provider for the direct minutes feature. Configured legacy analysis retains its
existing behavior. Neither route is a fallback for the other.

## Scheduling and persistence

- Automatic generation defaults on for this explicitly requested Live feature.
  Settings → AI → Meeting Skill can pause it. Disabling automatic generation
  prevents further automatic requests; an already sent request may complete its
  current checkpoint before yielding.
- Automatic discovery starts at this feature's first activation, not at the
  beginning of the user's library. A completed-recording callback also covers a
  recording that started before activation. Opening an older meeting exposes an
  explicit Generate minutes action, separate from automatic discovery.
- Minutes wait while capture, pause or final transcription is active. A
  dedicated native ChatGPT client owns a separate physical connection, so a
  background request cannot hold the foreground Live Ask connection's FIFO
  lease. Account changes and disconnect cancel every registered client.
- `meeting_minutes_jobs` persists pending/running/failed/completed state, source
  and skill snapshots, processing coverage, completed evidence checkpoints and
  result provenance. Lightweight status polling omits the private bodies.
- Pending jobs resume at launch. An interrupted running job becomes visibly
  retryable; an uncertain provider call is never silently replayed. Explicit
  Retry can continue completed checkpoints under the same provider identity or
  restart coverage for a newly selected account/model. Changed source or skill
  creates a new attempt with new provenance.
- A completed job and fresh `PromptResult` are committed in one transaction.
  Failure cannot delete a valid result, change the final transcript, or delay
  saving audio. Deleting a meeting removes its private jobs through the source
  foreign key. Deleting only minutes preserves their completion receipt; polling
  cannot silently recreate a deliberately removed result.

## Whole-source evidence

Minutes use the complete effective final transcript, including active text and
speaker corrections. The exact formatted evidence hash is separate from the
existing result freshness word hash. The engine reads ordered bounded source
chunks with overlap; each accepted extraction records a contiguous coverage
frontier and a bounded rolling meeting map. The map is lossy, and is not a
verbatim or exhaustive record. The complete transcript remains saved locally.

Candidate actions retain exact character ranges in the original source.
Quotations must match a contiguous byte-exact source passage. A separate skeptic
pass checks future work, a concrete deliverable, commitment/assignment,
attribution and scope before an action may remain confirmed. Confirmed actions,
conditional/proposed follow-ups and excluded candidates render separately.
Unknown owners, recipients and dates remain explicit. No actions is valid.

The default evidence-first format renders exactly four numbered summary notes,
each with a substantive headline and two to four sentences. The editable skill
guides content and wording within the four-note/evidence structure. Its worked
meeting example is illustrative and excluded from runtime source evidence.
Generation, format validation or quotation verification failure leaves a visible
failed job with no new published draft. Source and provider identity are checked
again after inference; publication revalidates the effective source atomically.
These checks do not guarantee perfect speech recognition or model judgment.

## Viewing and portable files

Each saved meeting shows minutes progress, any failure, explicit Retry, and Open
minutes when completed. Minutes reuse the existing editable/exportable result
tab, preserving the user's notes as a separate document.

Portable meeting artifacts are refreshed from canonical current data under the
same media-mutation lease as deletion. A missing source or deleted folder is
never recreated. File errors are separate from successful model output and
offer local Retry file export. Each launch reconciles completed jobs' artifacts
once, covering interruption between the result transaction and file export
without another inference request.

Settings and the private original skill are governed by
[versioned meeting preferences](live-meeting-preferences-v1.md). Live answer
wording follows [the live answer contract](live-answer.md).
