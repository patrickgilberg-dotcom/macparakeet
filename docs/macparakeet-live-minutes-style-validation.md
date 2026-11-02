# Skill-based minutes and personal answer style

Qualification dates: October 29–30, 2026 (America/Edmonton).
Installed signed Release source: `a3c1d2ff7ff5`. Initial feature source: `00e11427`;
narrative-audit repair: `03a33703`. Final native qualification passed.
The supported installer and strict/deep signature check passed with the existing
persistent signing identity; the original app executable hash is unchanged.

## Delivered behavior

After final local meeting transcription, the Live fork queues durable minutes
through its existing ChatGPT-plan connection. Every available source chunk is
reviewed, confirmed actions retain exact contiguous quotation ranges, and a
separate skeptic pass checks their commitment, attribution and scope. The
default output has four notes with two to four sentences each, confirmed
actions, separate conditional/proposed follow-ups and an excluded-candidate
audit when applicable. These checks do not make speech recognition or semantic
judgment infallible.

Settings → AI now exposes the meeting skill, Markdown preview, explicit
Save/Reload, default restore, version history, automatic-minutes control, and
personal answer-style instructions/examples. Style applies only to explicit
Live Ask wording; meeting facts and approval conditions keep priority. It does
not enter current/prior memory summaries or minutes evidence.

The app retains the complete original skill in private local settings and an
owner-only imported default. The repository and bundled default contain generic
rules/template only, without the personal worked meeting. Runtime minutes
exclude that illustrative meeting. Writing examples are never invented; the
local profile may be edited independently. The ChatGPT login grants generation,
not saved ChatGPT conversations or memory.

## Automated evidence

- Combined affected-area gate: **186 tests passed**, zero failures. This covers
  auth/client transitions, minutes engine/repository, settings, profile framing,
  live/project memory, UI-facing automation, interruption and artifact repair.
- Additional persistence/result gate: **237 tests passed**, zero failures.
  The focused selections overlap; their counts are not an independent sum.
- The complete suite ran **once** for this feature task at the initial feature
  source: **8,491 XCTest cases**, **36 skipped**, and **two assertion failures in
  one existing microphone recovery test**. The separate Swift Testing run
  passed all **30 tests**. This is not a clean full-suite result.
- That microphone test timed out waiting for initial readiness, then reported
  an unwaited notification expectation. Its synthetic PCM fixtures exposed
  more frames than they initialized. The test fixtures now initialize every
  exposed byte; production microphone code and readiness timeouts were unchanged.
  The diagnostic evidence does not establish uninitialized samples as the sole
  cause of the earlier timeout.
- After that fixture correction and the narrative-audit repair, a focused gate
  passed **63 tests**, zero failures: all **30 microphone recovery tests**,
  **17 minutes-engine tests**, **six minutes-automation tests**, and **ten live
  answer tests**. The full suite was not rerun. The final
  minutes-engine gate then passed all **18 tests**, zero failures, including the
  independently confirmed-commitment regression at `a3c1d2ff`.
- Independent reviews converged after fixing artifact reconciliation across
  restart, latest retry presentation, private example distribution and immediate
  account-transition invalidation. Dedicated background/foreground connections
  remain independently cancellable, with stable provider keys across restart.
- Local `no-mistakes` and Greptile CLI are unavailable. The committed review
  wrapper confirmed the missing Greptile executable; no hosted review is claimed.

## Native qualification

The initial feature build was installed through the supported signed Release
workflow. Native settings checks verified skill editing and saving, restoring
the exact imported default without losing the style profile, Markdown preview,
and two saved versions available for restore. The original source skill was
unchanged. The profile contains abstract phrasing preferences; no private email
body or worked-meeting example was published.

An explicitly generated synthetic meeting completed through the existing
ChatGPT-plan connection without another sign-in or permission prompt. This
first result **failed semantic qualification**: the action audit rejected an
uncertain speaker attribution, but one summary note still repeated the rejected
acceptance. That result is retained privately as pre-repair failure evidence;
it is not an end-to-end success.

The repair checkpoints each independent audit verdict together with a corrected
meeting map. Final notes consume that corrected map, and every candidate kind
is reviewed. Legacy incomplete jobs retain completed source coverage but must
redo their action audits under `reconciled-meeting-map-v2`. Already completed
results are not silently rewritten. Focused tests cover sequential corrections,
invalid corrected maps, and interrupted legacy progress resuming without
repeating completed source extraction.

On October 30, the final installed `a3c1d2ff7ff5` build passed the repaired native
workflow using a post-activation 33-second synthetic recording. It queued minutes
automatically after final transcription, without clicking Generate minutes.
The first synthetic file had predated feature activation, so explicit Generate
minutes was the expected path for that earlier test.

- The real ChatGPT-plan request reached terminal completion. One job produced
  one saved result, with **730/730 source characters** covered in one chunk and
  audit policy `reconciled-meeting-map-v2` recorded.
- The output contained exactly **four notes**, each with **two sentences**, and
  one confirmed action whose owner remained unknown. Native display and saved
  content review found no unsupported attribution of an anonymous acceptance
  to the named request recipient. Release approval remained withheld, required
  security and rollback conditions remained explicit, a suggested review stayed
  tentative, and a product capability was not converted into an assigned task.
- Every manifest-listed file was nonempty. Portable minutes Markdown and JSON
  matched the saved result. Both 33-second audio artifacts, `system-raw.m4a` and
  `meeting-playback.m4a`, passed full strict decoding.
- Ordinary Quit terminated the app; relaunch retained the same job, result,
  content and settings without duplicating the job or result. Content artifact hashes
  stayed unchanged. Launch reconciliation regenerated `manifest.json`; the
  regenerated manifest was validated rather than claimed byte-identical.
- Final native Settings showed automatic minutes and personal style enabled,
  the exact original skill saved, a 541-character style profile, two historical
  versions and no unsaved edits. The original skill remained unchanged.

The content-free native evidence is recorded in
[the final evidence file](../benchmarks/chatgpt-live/results/2026-10-30-minutes-style-native-e2e.json).

## Recovery and scope

Completed source/skill/evidence checkpoints are private durable state. Interrupted
running work becomes explicitly retryable; uncertain model calls are not
silently replayed. Pending work resumes automatically. A completed job and its
fresh result commit together against a revalidated current effective source.
Deleting only minutes retains a completion receipt; deleting a meeting cascades
its private jobs. File export is repairable locally without repeating inference.

Automatic discovery is restricted to future meetings from feature activation;
older meetings require an explicit Generate minutes action. Minutes wait during
recording/final transcription and yield between background requests. The new
physical connection cannot hold Live Ask's request lease. Optional legacy
analysis is skipped when unconfigured and preserved when configured.

The existing calendar, project/latest-prior context, capture, audio recovery and
three-minute rolling-memory qualification remains separately documented in
[the earlier report](macparakeet-live-validation.md). This feature work does not
constitute a new multi-hour microphone/system-audio soak. Final free disk space
was approximately **5.4 GiB** after removing this worktree's rebuildable caches;
user recordings and saved data were preserved.
