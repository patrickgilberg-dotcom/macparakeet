# Immediate meeting focus and explicit answer refresh

Status: in progress.

## Scope

Add a fast immediate raw-speech layer around the latest 30 seconds, extending
selection to preserve complete questions or speaker turns. Retain the completed
three-minute focus summary, cumulative general memory and separately attributed
calendar/project/style context. Give a live answer a visible stable anchor and
capture time, and offer Update answer when meaningful new discussion or a
correction supersedes that snapshot.

## Invariants

- The new immediate projection and freshness comparison are local. They add no
  model-summary call to explicit Ask or Update answer.
- Complete relevant questions remain available beyond a strict 30-second cutoff.
  Silence alone cannot make a captured answer stale.
- Transcript, immediate source, recent source and notes are captured together
  before asynchronous preference or context preparation.
- The priority is explicit current question, immediate raw focus, completed
  three-minute focus, then general/background context. New explicit corrections
  and existing approval conditions remain authoritative.
- Completed answers stay readable. Refresh is explicit and cancels an active
  old request before preparing a fresh snapshot. Cancelled partial output never
  becomes a successful assistant/history turn, and late output cannot write
  into a newer answer.
- Capture, recovery, final minutes, saved preferences, source-gap warnings,
  account/model pinning and complete available-source coverage remain intact.
- UI time labels describe context capture, not an acoustic speech boundary.

## Work

- [ ] Add and verify the immediate-source and complete-question projection.
- [ ] Capture immediate/recent/full context atomically and prioritize it in Ask.
- [ ] Detect meaningful new discussion/corrections locally and scope state to
  the active answer and recording.
- [x] Show question/turn anchor, capture time and explicit Update answer action.
  The action remains available during and after generation; VM state gates it.
- [x] Update the governing context contract and preserve prior qualification labels.
- [ ] Add targeted boundary, freshness, cancellation, snapshot and source-priority
  tests, including during an in-flight answer.
- [ ] Complete independent review and the required source-specific test gates.
- [ ] Qualify a genuine synthetic cloud flow and the signed installed app,
  including visible refresh and retained user data.

## Verification

Pending. Earlier focus, calendar/project, recovery and minutes/style evidence
retains its original source labels and does not qualify this new projection or
refresh interaction. Run focused tests while iterating and the full suite at
most once for this task. Report functional, timing, native capture and synthetic
qualification separately; do not turn a simulated timeline into a hardware
recording or latency guarantee.

## Verification progress

The first build exhausted temporary disk space during debug-symbol generation;
no Swift source errors or tests were reported. The focused gate was rebuilt with
`-debug-info-format none` (Debug assertions retained): **189 tests passed**,
zero failures, in **9.749 seconds**. Full regression, signed installation,
real-VM cloud and native system-audio qualification remain pending.
