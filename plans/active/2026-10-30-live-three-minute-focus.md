# Recent meeting focus with general background

Status: in progress.

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

- [ ] Add structured recording-time recent-source projection and panel wiring.
- [ ] Add separate cached recent focus while retaining cumulative general memory.
- [ ] Prioritize question/fresh speech/recent focus and inject general background.
- [x] Update native context disclosure and governing contract.
- [ ] Focused boundary, freshness, cancellation, cache and request-shape checks.
- [ ] Independent review, signed Release build and installed qualification.

## Verification

Pending. Earlier recording, recovery, calendar/project and minutes/style results
retain their original revision labels and do not qualify the new context shape.
No new cloud latency, multi-hour native recording or arbitrary-duration claim is
made by this change.
