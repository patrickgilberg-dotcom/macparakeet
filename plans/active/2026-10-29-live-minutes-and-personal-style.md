# Automatic skill-based minutes and personal answer style

Status: in progress.

## Scope

Build the three requested follow-ups in the existing personal Live fork:
automatic meeting minutes using the user's evidence-first SKILL.md, a native
editor with version restore, and an editable answer-style profile. Continue
using the existing explicitly authorized ChatGPT plan connection. Account
sign-in does not expose ChatGPT conversation history or memory.

## Invariants

- Capture, local final transcription, calendar naming and latest-prior project
  context retain their qualified behavior. Audio remains local.
- Final minutes use the complete effective final transcript as their factual
  source. Ordered chunks cover long transcripts; summaries never silently
  replace missing source. Actions carry exact contiguous verified quotations.
- Default output has exactly four substantive summary notes, verified actions,
  separate conditional/proposed follow-ups, and excluded-candidate audit where
  applicable. Unknown owners and dates remain unknown.
- Durable generation state survives app interruption. Completed output is only
  published after terminal provider success, validation and source revalidation.
  Generation failure cannot undo transcription or delete prior valid output.
- Deleted sources cannot be resurrected. Skill/profile examples supply
  instructions or style only and cannot become meeting facts.
- Minutes wait while capture is active; foreground Ask retains priority.
- Profile/skill settings live only in the isolated Live data namespace; preserve
  the user's original SKILL.md and upstream app. No API-key or billed fallback.

## Work

- [x] Versioned settings, private original skill import, sanitized bundled default,
  native editor and style profile. The private worked example is not published.
- [x] Full-source evidence-first generation and durable job/result persistence.
- [x] Automatic finalization/recovery wiring and visible minutes status/retry.
- [x] Style integration with factual priority and focused coverage.
- [ ] Independent review and focused gates; at most one final full suite.
- [ ] Stable signed release, installed native workflow verification, evidence.

Initial focused gate:64 checks passed,0 failures. Final additions under review
include cross-client account-transition invalidation, final stage JSON priority,
and four portable-file recovery checks. The full suite has not yet run for this
new feature task. Earlier task's8434-test gate is not this task's final gate.
