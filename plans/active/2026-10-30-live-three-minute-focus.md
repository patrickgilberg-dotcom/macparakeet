# Recent meeting focus with general background

Status: complete. Qualified installed code: `d7e71ad968b4`.
Native connection and relaunch checks passed; recent-focus behavior is qualified
through the production Core helper and VM/flow tests, with the native limits below.

## Scope

Make Live Ask focus on the latest completed three-minute summary and fresh
speech, while also including cumulative general meeting context. Keep the
existing three-minute background cadence and fast explicit-answer path. A
question does not wait for a newly generated sliding-window summary.

## Invariants

- Fresh recognized speech and explicit corrections remain authoritative. The
  recent summary carries its actual completed recording-time window.
- Recent source selection uses numeric word timing in both plain and rich text
  modes, including words crossing a window boundary. Silence ages old focus out.
- General memory retains complete available-source processing, bounded raw text,
  exact question excerpts, uncertainty, approval conditions and correction rules.
- Before a summary exists, use available transcript context and show that the
  summary is not ready. Never invent summary coverage.
- Summary inputs remain current-meeting source only. Event preparation, the
  latest prior project meeting and personal style stay separate answer context.
- Provider changes, source edits, reset, cancellation and failed/partial model
  output cannot publish an invalid focus summary. Preserve capture, recovery,
  final minutes and saved settings.
- Source gaps stay visible. Both summaries are lossy; the full local transcript
  and durable audio remain unchanged.

## Work

- [x] Add structured recording-time recent-source projection and panel wiring.
- [x] Add separate cached recent focus while retaining cumulative general memory.
- [x] Prioritize question/fresh speech/recent focus and inject general background.
- [x] Update native context disclosure and governing contract.
- [x] Initial focused boundary, freshness, cancellation, cache and request-shape
  gate: **163 passed**, zero failures.
- [x] Independent review and genuine cloud functional qualification using the
  production Core through the already authorized, persistently signed helper.
- [x] Repair transcript/focus snapshot consistency across asynchronous preference
  loading and add a gated regression at `d7e71ad9`.
- [x] Final affected-area gate, including the added regression: 164 tests passed.
- [x] Complete the once-per-task full suite on the compiled `d450b27b` stage:
  8,519 XCTest cases, 36 skipped, zero failures, plus 30 Swift Testing tests.
  Do not repeat it for this task.
- [x] Finish the signed Release build, supported install, native connection and
  relaunch checks. The focus renderer compiled; no new native recording drove it.

## Verification progress

- Feature source: `a55661e7`; UI formatting: `d450b27b`; final two-line snapshot
  consistency repair and its regression: `d7e71ad9`.
- The initial affected-area gate passed **163 tests**. The final affected-area
  gate at `d7e71ad9` passed **164 tests**, zero failures, in **11.268 seconds**,
  including the gated transcript/focus snapshot-race regression.
- The one full run completed successfully on the compiled `d450b27b` stage:
  **8,519 XCTest cases**, **36 skipped**, **zero failures**, in **581.106 seconds**;
  the separate Swift Testing run passed **30 tests**. The final `d7e71ad9`
  snapshot fix was committed after that test binary compiled and passed the
  final focused gate. The full suite was not repeated.
- A genuine ChatGPT-plan `focuscheck` completed five simulated updates through
  minutes 3, 6, 9, 12 and 15: **ten completed summary calls**, followed by **three
  completed answers** with **zero additional summary calls during Ask**.
- General memory covered **21,201 source characters** through minute 15; fresh
  speech expanded the final source to **21,296 characters**, all processed or
  present as raw context. The cached focus window was **12:00–15:00**, while
  the fresh source window was **12:10–15:10**.
- The generic latest-question answer and explicit current-question answer used
  the corrected synthetic cap and denied an approved Friday production launch.
  The explicit earlier-history question recovered the older route owner and
  corrected cap. Recent focus did not import those older route/budget facts.
- One lexical approval flag in the helper report is false because its markers
  missed a curly-apostrophe denial and the phrase that no launch had been
  approved. Manual review confirms the answer denied launch approval. The flag
  is retained rather than reported as an all-green lexical result.
- The signed helper was a DEBUG build with Core matching the final feature
  implementation. It ran while the full suite was active. Its timings do not
  qualify native optimized Release performance, capture, recognition or UI.
- The supported signed Release build `d7e71ad968b4` succeeded, built at
  `2026-10-30T17:26:16Z`. Installation and strict/deep signature verification
  passed with the existing persistent identity. Native Test Connection displayed
  “Answer completed.” Automatic-minutes and style settings remained enabled.
- Ordinary Quit terminated the app; relaunch returned to idle Meetings with no
  recording locks. All **17 meeting IDs**, existing completed minutes jobs and
  the settings hash were retained. The original app hash was unchanged, and a
  private consistent SQLite backup passed its integrity check.
- No new native recording or 180-second cadence run drove the focus disclosure.
  Its renderer compiled; the production focus path was exercised through the
  Core helper and VM/flow tests. Local `no-mistakes` and Greptile CLI were
  unavailable; independent reviews converged.

Detailed evidence and remaining limits are tracked in
[the focus validation report](../../docs/macparakeet-live-focus-validation.md).
Earlier recording, recovery, calendar/project and minutes/style results retain
their original revision labels. No new multi-hour native recording or
arbitrary-duration claim is made by this change.
