# Live board and automatic project preparation

User intent: produce a project brief automatically 15 minutes before an explicitly project-assigned calendar occurrence; carry it into the meeting quietly. Extract live decisions, actions, questions and latest-meeting carryover, supported by clickable exact quotations. Include the entire saved user-notes source alongside the transcript.

## Scope and invariants

- Separate generated board/preparation from authored Notes and event context.
- Select only the latest prior project meeting; unavailable transcription never substitutes an older row. Notes retain their own provenance and do not prove spoken agreement or completion.
- Validate quotes against raw sources. Keep unknown owners/dates unknown; preserve conditions and proposals. Previous actions are completion-unverified.
- Reuse the 180-second cancellable background lane for live extraction; explicit Ask preempts and awaits it. Preserve Now/complete questions/recent/general context order and explicit Update answer.
- Generate prep only for saved project assignments, with separate local derived artifacts and source/account/context validation. Calendar reading never creates events or tasks.
- Preserve capture, recovery, local audio/transcripts, stable signing, existing permissions, exact event titles and original app isolation.

## Implementation and verification

- [x] Core structured evidence extraction, whole-source chunk coverage, account-scoped caching and validation.
- [x] Full previous-notes context without silent prefix omission.
- [x] Separate durable generated prep and automatic 15-minute scheduling; live cache reuse.
- [x] Minimal live prep disclosure and Board tab, source quotation inspection.
- [x] Focused synthetic tests for evidence, notes, scheduling, stale sources, cancellation, Ask priority and persistence (253 passed).
- [x] Genuine synthetic ChatGPT end-to-end completion and signed build/install. Native regular/compact scrolling passes; screen acceptance subsequently passed in the native host.
- [x] Single full-suite attempt and independent review, contracts and validation report.
- [x] Final quiet on-screen acceptance: installed Prepare/calendar/draft cancellation verified, synthetic production card and quote/full-source controls clicked through Cua, native assertions passed. No new audio test.
- [x] Fork handoff: branch pushed and PR 1 updated through the existing GitHub CLI connection. The read-only connector returned 403; its metadata edit was not treated as success.

Source implementation: b962887f + actor-isolation fix 1e7588be. Signed Release 1e7588be8105 installed and launched, deep/strict signature valid; all 21 baseline records preserved, database quick_check=ok, original app unchanged and private SQLite backup saved.

Final integrated checks: 301 tests, one native AX capability skip, zero failures. Normal-path regressions: 24 tests, one intentional seeder skip, zero failures. Final genuine synthetic flow completed 17 requests (8 extraction, 3 reconciliation, 4 summaries, 2 answers), all checks including owner=Maya/deadline=by Friday passed, zero foreground extraction/summary calls. First text 1.105s/1.767s; completions 2.005s/2.319s. Full-suite attempt: 8617 XCTest cases, 35 skips, 8 assertions in 7 environment-dependent cases; 30 Swift Testing cases passed. Full suite not repeated. The final literal prompt refinement and actor cleanup are qualified by focused/provider/build checks after that attempt.

Independent review closed missing/deleted project scope, frozen manual-context matching, interrupted-progress caching and derived-copy deletion. Evidence/limits: docs/macparakeet-live-board-preparation-validation.md. Manual unlock received. The installed Prepare screen passed read-only acceptance and draft Cancel restoration. The actual card expand/collapse and quotation/full-source controls passed through Cua in the synthetic native host; its source-button case passed in 61.154s with no skips/failures. No new audio or saved context, all helper/awake processes ended, and the app is left on Meetings. All requested implementation and quiet acceptance work is complete; full-suite path limitations remain documented.
