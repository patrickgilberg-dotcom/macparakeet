# Recent meeting focus and general background

Qualification date: October 30, 2026 (America/Edmonton).
Installed signed Release source: `d7e71ad968b4`, built at
`2026-10-30T17:26:16Z`. Feature implementation: `a55661e7`; UI formatting:
`d450b27b`; final transcript/focus snapshot consistency repair: `d7e71ad9`.
Final focused tests, the supported installation, native connection and relaunch
checks passed. Recent-focus behavior is qualified through the production Core
helper and VM/flow tests; a new native recording did not drive the focus UI.

## Resulting behavior

Live Ask prioritizes the current question, fresh recognized speech and the
latest completed three-minute summary. A separate cumulative general summary
supplies earlier decisions, corrected facts, constraints and unresolved issues.
An explicit question about older discussion can use that background and exact
source excerpts. Fresh corrections remain authoritative, and older approval
conditions remain in force until explicitly changed.

The background cadence remains 180 seconds. Each recent summary is labeled with
its actual completed recording-time window. Ask reuses it and adds fresh speech
without making a new recent-summary call per question. This is not a newly
summarized sliding window ending at every Ask. Before a summary is ready, the
available raw transcript supplies context and the missing summary is disclosed.

Numeric word timing selects the recent source independently of plain/rich text
preferences and includes words crossing the start boundary. Silence ages old
focus out. The recent summary is bounded at 3,000 characters; general memory
retains its 8,000-character bound and existing complete-source processing, raw
suffix and question-specific exact excerpts. Both summaries remain lossy.

The native last-answer disclosure now shows recent focus with its completed
window and general background even when the full raw transcript is included.
Preview gaps, raw/summary coverage, timing and missing-summary notices remain
visible. Event preparation, the latest prior project meeting, personal style
and writing samples remain separate answer inputs; none enters either
current-meeting summary. Capture, final minutes, durable audio and saved
settings retain their existing boundaries.

## Automated evidence

- Initial affected-area gate: **163 tests passed**, zero failures. This includes
  word-window boundaries, plain/rich selection, silence, source/cache changes,
  cancellation, request priority, unchanged general coverage and relevant live
  answer paths.
- A final two-line snapshot repair at `d7e71ad9` captures the transcript and
  recent source together before asynchronous preference loading. The final
  affected-area gate passed **164 tests**, zero failures, in **11.268 seconds**,
  including its gated snapshot-race regression.
- The one full-suite run completed successfully on the compiled `d450b27b`
  stage: **8,519 XCTest cases**, **36 skipped**, **zero failures**, in
  **581.106 seconds**. The separate Swift Testing run passed **30 tests**.
  The `d7e71ad9` snapshot fix was committed after this test binary compiled;
  it passed the final focused gate described above. The full suite was not
  repeated for this task.
- Independent reviews converged. Local `no-mistakes` and Greptile CLI are
  unavailable; no hosted review or CI success is claimed.

## Genuine cloud functional check

The existing authorized helper identity was retained and persistently signed.
Its DEBUG executable used the production Core implementation matching the final
feature code. The `focuscheck` command read only generated synthetic source;
it did not read the user meeting database, audio, transcripts, meeting skill or
writing examples. The full synthetic report is retained privately as
`QA/2026-10-30-three-minute-focus/cloud-focuscheck.json`.

Five simulated snapshots at minutes **3, 6, 9, 12 and 15** completed **ten model
summary calls**: one general and one recent update at each stage. No wall-clock
15-minute recording was made. General coverage reached **21,201 characters**
through minute 15. The final source added fresh speech at 15:10, reaching
**21,296 characters**; every source range was either processed into general
memory or present in raw context.

All three real ChatGPT-plan answers reached terminal completion. Each reused
the completed **12:00–15:00** recent summary, included the fresh
**12:10–15:10** recognized source window, and made **zero summary calls during
Ask preparation**. The separate general and recent blocks were present in
all three requests.

Manual review of the synthetic outputs confirmed:

- A generic latest-question request stayed on the current cap/launch question.
  It recovered the earlier corrected cap of **$38,000** from general context and
  declined to promise a Friday production launch.
- An explicit current-question request retained the corrected figure and denied
  launch approval rather than turning a proposed date into a commitment.
- An explicit earlier-history question recovered the older route owner and the
  corrected cap. Recent focus itself did not import the old route or numeric
  budget facts, demonstrating that general context remained available separately.

The report retains one false lexical approval marker on the second answer.
The helper's literal phrases missed the curly-apostrophe denial “can’t promise”
and the statement “no production launch has been approved.” Manual inspection
confirms that the answer denied approval. This is a heuristic false negative,
not an all-green lexical result, and the original flag was not rewritten.

The helper run overlapped the full test suite and used a DEBUG executable.
Its timing values do **not** qualify optimized native Release latency, microphone
capture, speech recognition or visible app rendering.

## Installed build and native checks

The supported Release workflow built `d7e71ad968b4` successfully and installed it
with the existing persistent signing identity. The installed bundle passed
strict/deep signature verification. Native Settings showed automatic minutes
and personal answer style enabled. Test Connection visibly reached
“Answer completed.” This verifies the installed app's connection; it does not
represent a new native recording using the focus request.

Ordinary Quit left zero installed-app processes. Reopening returned to idle
Meetings with no recording locks. All **17 meeting IDs** and existing completed
minutes jobs were retained, the saved settings hash was unchanged, and the
original MacParakeet executable hash was unchanged. A private consistent SQLite
backup passed its integrity check. Rebuildable test output was removed after
verification, leaving approximately **5.5 GiB** free; installed app files, source,
recordings and settings were retained.

The public synthetic qualification record is
[the final evidence file](../benchmarks/chatgpt-live/results/2026-10-30-three-minute-focus-e2e.json).

## Qualification limits

The full-suite result applies to compiled `d450b27b`; the final snapshot repair
at `d7e71ad9` passed its 164-test focused gate. The suite was not rerun.

No new native live capture or 180-second cadence run drove the recent-focus
renderer. That renderer compiled in the installed Release, while the focus
production path was exercised through the Core helper and VM/flow tests. The
helper's concurrent DEBUG timing values remain unqualified for native Release
performance. Native Test Connection and relaunch do not change those limits.

Earlier calendar, project, recording recovery and minutes/style evidence keeps
its measured source labels in [the main report](macparakeet-live-validation.md)
and [the minutes/style report](macparakeet-live-minutes-style-validation.md).
This work does not provide a new multi-hour native capture soak, perfect semantic
retention, a freshly summarized exact sliding window for every question or an
arbitrary-duration recording guarantee.
