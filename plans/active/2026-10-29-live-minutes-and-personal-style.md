# Automatic skill-based minutes and personal answer style

Status: complete. Qualified installed code: `a3c1d2ff7ff5`.

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
- [x] Independent review and focused gates; one full suite run is complete with
  the qualification below.
- [x] Stable signed release, installed native workflow verification, evidence.

## Verification progress

- Initial focused gate: **64 passed**, zero failures.
- Expanded affected-area gate: **186 passed**, zero failures, including auth
  transitions, preferences, minutes persistence/generation, live/project memory,
  automation and artifact repair.
- Additional persistence/result gate: **237 passed**, zero failures. These
  focused selections overlap and must not be summed as independent coverage.
- Full suite ran once at `00e11427`: **8,491 XCTest cases**, **36 skipped**,
  **two assertion failures in one existing microphone recovery test**;
  **30 Swift Testing tests passed**. The full suite is not green and must not be
  rerun for this task. The microphone test hit initial-readiness timeout and
  consequently left its notification expectation unwaited.
- Synthetic audio test fixtures were corrected to initialize all exposed PCM
  bytes. Production capture code and readiness timeouts were unchanged. The
  earlier timeout's exact cause is not proven by that fixture finding.
- The initial installed native minutes test found a real narrative inconsistency:
  an audited rejection did not remove the unsupported acceptance from final
  notes. `03a33703` reconciles every audit verdict into the meeting map used for
  those notes, preserving completed source coverage on legacy incomplete jobs.
- After that repair and the fixture correction: **63 focused tests passed**,
  zero failures, including all **30 microphone recovery tests**, **17 minutes
  tests**, **six automation tests**, and **ten live answer tests**.
- Final minutes-focused gate at `a3c1d2ff`: **18 passed**, zero failures,
  including independently confirmed commitments. Supported signed Release
  installation and strict/deep signature verification passed; the original app
  executable hash is unchanged.
- Native editor save, exact default restore, preview, saved history and profile
  persistence passed on the initial installed build. The original skill remains
  unchanged. The first synthetic minutes result is retained as failure evidence,
  not a qualified success.
- Final installed native workflow passed on October 30: a new 33-second
  synthetic import queued minutes automatically, reached real ChatGPT terminal
  completion, covered **730/730 source characters**, and saved one job/result
  under the corrected audit policy. Four notes contained two sentences each;
  the confirmed action retained an unknown owner, unsupported acceptance was
  absent, and approval conditions and tentative proposals remained explicit.
- Manifest-listed artifacts were nonempty, portable Markdown/JSON matched the
  result, and both audio files strict-decoded. Ordinary Quit/relaunch preserved
  the same job/result/content/settings without duplicate jobs or results. Content
  artifact hashes were unchanged; the reconciled manifest was revalidated.
- Final native Settings confirmed the saved original skill, enabled automation
  and style, the 541-character profile, two historical versions and no unsaved
  edits. Final free disk space was about **5.4 GiB** after own rebuildable-cache
  cleanup; user recordings/data were retained. No new multi-hour hardware soak
  or clean rerun of the full suite is claimed.
- Independent reviews converged. Local `no-mistakes` and Greptile CLI are
  unavailable; no hosted review or CI success is claimed.

Detailed evidence and remaining limits are tracked in
[the feature validation report](../../docs/macparakeet-live-minutes-style-validation.md).
