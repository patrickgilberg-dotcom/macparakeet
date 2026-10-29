# Live context end-to-end and recording recovery qualification

Status: implemented and locally qualified; personal-fork PR remains open.

## Requested outcome

Qualify the installed calendar title, private event preparation, only-latest project meeting and fresh spoken corrections through actual completed Live Ask responses. Exercise normal artifact finalization, native interruption/recovery and bounded accelerated long-media durability. Recommend five next improvements, including editable personal-skill minutes and personal answer style; do not imply the ChatGPT login supplies account history.

## Invariants

- Preserve real meetings, original app, approved connections and stable signing identity.
- Use labeled synthetic reference meetings and a dedicated QA project. No Google event writes. Restore the previously blank event preparation after testing; retain frozen QA artifacts.
- No silent inference replay. Incomplete provider output must not become a completed recovered answer.
- A failed chat checkpoint must still honor End by stopping audio and retaining the recovery lock. Recovery failure must leave source and checkpoints for retry.
- Recovery imports the stable chat identity idempotently and must not overwrite a chat the user already edited.
- Distinguish accelerated encoded duration, actual native capture duration and automated source coverage. No arbitrary-duration or zero-loss guarantee.

## Evidence and work

- [x] Native primary Google event preparation saved/reopened with selected QA project.
- [x] Native imports and project assignment of older and latest synthetic meetings.
- [x] Three actual installed-app questions: current $7,000 correction + event 48-hour requirement + latest Nina/Thursday action; event marker + latest code name; later $6,500/security/checklist corrections.
- [x] Actual 3- and 6-minute context refreshes observed during 411.277 seconds of native capture.
- [x] Normal finalization preserved exact calendar title, project, note, six chat messages and transcript; all three audio files fully strict-decoded.
- [x] Pre-fix native SIGKILL/relaunch recovery preserved title/project/note/transcript and all three decodable audio files, but lost live chat. Regression reproduced; fix required.
- [x] Read-only long-session audit and 142 focused baseline checks, including synthetic process-kill/recovery journeys.
- [x] Add and independently review monotonic recording-owned chat checkpoints, cancellation/ownership guards, idempotent recovery import and content-free deletion receipts.
- [x] Focused integration tests, bounded accelerated two-hour writer test and once-per-task full gate: 8,434 XCTest / 36 skipped / zero failures plus 30 Swift Testing.
- [x] Persistent-signed build/install after DB backup; native 173.076-second interrupted recovery restored four messages and 198.734-second normal Stop preserved two messages. Both retained exact title/project/context/note and all validated artifacts/audio.
- [x] Restore blank event preparation and no project through Save/reopen, preserving frozen recording snapshots; publish content-free evidence and update personal-fork PR.
- [x] Fix the additionally reproduced calendar startup selection race; 63 focused checks plus native startup passed without manual Refresh. Final installed source is `a0f4b3c6ce15`.

## Known limits

At the first disk check only about 2.2 GiB was free. Two hours of dual AAC sources plus playback uses roughly 230 MB, while each 16 kHz mono Float32 scratch stream adds roughly 461 MB; overlapping processing can need several such files. Capture has no fixed duration cap, but the reviewed path has no proactive free-space monitor, an unbounded raw-buffer stream, and no explicit sleep-prevention assertion. AEC cleanup has a four-hour cap with raw fallback. Tests cannot establish immunity to disk exhaustion, power failure, device failure or indefinite native sessions.

The new long writer test initially exposed harness issues (accelerated encoder drain timing and a Foundation process-wait hang); retain those failed logs alongside the final qualified outcome. A two-hour encoded fixture is not a two-hour real-time meeting soak.

Signed source `9447f78bcb2e` passed the native interruption/recovery and normal-save
replays after the user unlocked the Mac. The final calendar-only startup repair
`a0f4b3c6ce15` passed its focused gate and installed native startup check. The full
regression run is attributed to `9447f78bcb2e`; it was not repeated. Cleanup is
complete, all three macOS grants remain active, and no recording locks remain.
Detailed limits, source labels and the observed recognition conflict are in
`docs/macparakeet-live-validation.md`.
