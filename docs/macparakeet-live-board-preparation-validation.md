# Live evidence board and automatic project preparation

Implementation: `b962887f`, followed by the calendar actor-isolation fix `1e7588be`.
Installed signed Release: **1e7588be8105**, built **2026-10-31T19:29:14Z**.
This is the personal Live fork, not an upstream release qualification.

## Result

- Upcoming Google occurrences explicitly assigned to a project become eligible for automatic prep in the fifteen minutes before their start. The app polls every 60 seconds while running and awake. Shared occurrences are eligible through explicit project assignment; unselected shared events never enter inference.
- Preparation reads only the latest eligible prior project meeting and its complete saved notes source. An unavailable latest transcript never substitutes an older completed recording. Notes-only availability is separately labeled.
- A small collapsed project card carries ready preparation into the call. Ask receives it as historical background, alongside the frozen manual event context. The current explicit question, complete immediate speech, recent three-minute summary and general meeting context retain priority.
- The Board tab shows decisions, actions, questions, personal notes and historical carryover. Owners and relative deadlines require quoted support. Resolution and reopening require later raw-transcript quotations; silence and personal notes cannot establish them.
- Quotation buttons disclose captured source text rather than jumping to a potentially corrected live line. Generated items never overwrite authored notes or preparation.
- Capture alone permits preparation for a back-to-back meeting. Current live AI work preempts and awaits it. Completed checked chunks survive cancellation, while incomplete responses and partial boards never become completed coverage.
- Generated prep is private, atomic derived storage. Full source-meeting deletion removes matching copies, prevents delayed writes and durably retries failed cleanup. Audio-only removal and unrelated source files are preserved.

See the [contract](../spec/contracts/live-meeting-board-and-preparation.md).

## Focused verification

The final integrated run executed **301 tests, one skipped, zero failures**, in **16.694s**. It covers Core extraction, full notes, exact citations, unsupported owner/date rejection, chronological closure/reopening, account/source cache boundaries, cancellation progress, Ask priority, project/event selection, private storage/deletion, native bounded scrolling and existing live focus/Update behavior. Google Calendar and calendar auto-start regressions also passed.

The skipped native source-button test could not obtain SwiftUI Accessibility nodes from the XCTest host. The Mac was locked; Cua independently reported that native apps could not be accessed. The regular and compact board scrolling/layout test passed. A first development smoke harness incorrectly required offscreen AX export and failed; the final harness separates layout from unavailable screen capability. No quotation-click acceptance is claimed from a skipped test.

Changed Swift files passed strict swift-format lint and whitespace checks. Independent review closed deleted/missing project invalidation, frozen manual-context matching, interrupted extraction progress and derived-copy deletion findings. Local no-mistakes and Greptile executables were unavailable. No hosted CI success is claimed.

## Genuine ChatGPT flow

[The synthetic report](../benchmarks/chatgpt-live/results/2026-10-31-board-preparation-e2e.json)
comes from the production preparation/board engines and live Ask/Update ViewModel, using the existing pinned ChatGPT-plan client and normal terminal validation. It uses an in-memory repository, temporary private prep storage, generated event identity and synthetic transcript/notes. It does not fetch the user's calendar, open the user database, read personal skills/examples or record audio.

All **17 requests terminally completed**: eight board extraction calls, three reconciliation calls, four memory calls and two explicit answers. All structural and answer checks passed.

- The exact Google occurrence title, including surrounding spaces and an emoji, was retained. Only the latest project source was supplied; an older decoy never appeared in model input.
- The entire long notes source was retained and processed, including exact evidence for `NOTE-TAIL-73` beyond the initial note chunk. Typed notes stayed `noted`, not spoken commitments. Authored event context was unchanged.
- The extracted action populated **Maya** and **by Friday**, supported by the exact quotation containing the recorded named speaker's first-person acceptance. Completion remained unverified. Attribution to a transcript label is not independent identity verification.
- Cached prep entered both explicit answer requests without generation on the cache-read path. The live board included current speech, current notes, latest prior speech and latest prior notes.
- The first answer used the fresh **$32,000** cap, the prior report and personal retention reminder, and retained the production security-approval condition.
- Later recognized speech offered explicit Update without making an answer automatically. Update used **$29,000**, described report completion as unverified, and retained the previous answer.
- Both foreground answers made **zero board extraction and zero summary calls**.

| Synthetic helper observation | Ask | Update |
|---|---:|---:|
| First meaningful text | 1,104.6ms | 1,767.3ms |
| Completed answer | 2,004.6ms | 2,319.4ms |

These are two generated-source Debug-helper observations, not native acoustic/pixel latency, percentile guarantees or an API-provider comparison. Numeric source time tests the 15-minute and live-context policies without a wall-clock meeting wait. The first qualification showed correct context but omitted structured owner/deadline fields; human review led to the final prompt refinement and explicit real-provider assertion above. Both private attempt reports are retained; the public report is the final qualification.

## Full-suite gate and source qualification

The task's single full-suite attempt completed **8,617 XCTest cases**, with **35 skipped** and **8 assertion failures in 7 cases**, in **414.829s**. All failures depended on the deliberately isolated `MACPARAKEET_DEBUG_APP_STATE_DIR`:

- Three AppPaths cases expected normal app/log/custom-artifact paths.
- Config and meeting-split CLI cases expected a custom artifacts preference to outrank the explicit debug root.
- The local CLI working-directory case compared `/private/tmp` against `/tmp`.
- The opt-in fixture seeder refused a root outside its required system temporary directory.

The separate Swift Testing runner passed 30 tests in 3 suites. A subsequent targeted **normal-path run passed 24 tests, one skipped**, with zero failures; fixture seeding skipped as intended without its opt-in root. This does not convert the isolated full-suite run into a green gate. The full suite was not repeated.

The full run precedes the final literal owner/deadline prompt refinement and calendar capture-isolation cleanup. The 301-case integrated run, normal-path checks, final provider qualification and signed build cover the resulting implementation. The new native smoke test was added after the full attempt and is included in the focused result above.

## Installation and data checks

The supported `run_live_app.sh` and `install_live_app.sh` workflows built and installed the app with the existing persistent signing identity. Deep/strict signature verification passed after installation, and the installed Info.plist identifies `1e7588be8105`. The app launched successfully; no permission reset or new account setup was requested.

The database passed `PRAGMA quick_check`. All **21 pre-install meeting IDs remain**, including every baseline row. A consistent SQLite backup and structural before/after evidence remain privately outside the repository. The original `/Applications/MacParakeet.app` executable hash is unchanged. No new audio recording was started by this task.

The final app's on-screen Prepare/card/quotation acceptance is **pending manual Mac unlock**. The unlock request remains pending; a temporary display-awake assertion prevents another idle lock during that check. Native audio/capture tests from the prior focus task remain source-qualified in [the previous report](macparakeet-live-now-validation.md); this change does not repeat them or claim a new multi-hour recording soak.

## Use

Open an upcoming meeting's **Prepare** screen, choose a project, add any authored context and save. The automatic-prep toggle controls the fifteen-minute behavior. **Prepare now** saves the current draft and generates explicitly. During recording, expand the quiet **Prepared** card when useful, or open **Board** for source-backed follow-ups. Current questions and fresh speech keep priority in Ask.

Preparation is best effort while the app is running and awake. A newly saved/processing latest meeting can invalidate an earlier ready brief; the app retains latest-only honesty rather than quietly substituting older context. Summaries and extraction remain lossy, with complete original source artifacts authoritative.
