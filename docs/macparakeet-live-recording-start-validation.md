# Floating flower and recording-start qualification

## Floating-indicator investigation

The installed original is MacParakeet 0.8.10, source `394e630b4af7`.
Live's recording tile, floating pill controller and Merkaba renderer match that
source. The supplied screenshot showed an almost opaque circular surface over
the rosette, while the green stem remained visible. Ordinary Starting-state
dimming affects both and does not explain that selective occlusion.

An isolated native check used the real pill controller without capture,
accounts or user data. One case passed with zero skips/failures in **50.385s**.
Fresh Starting, Recording, preserved re-show, interrupted completion,
back-to-back start and direct Recording all retained exactly one panel. Both
maximum background and icon presentation-position deltas were **zero points**.
On-screen inspection showed the original white flower. A separate quiet check
of the installed `571fa9bc26bc` Live app, with its main window closed, also showed
a normal flower and exactly one 118-by-150-point recording window. Both quiet
recordings were stopped normally and retained under QA titles.

The routine flow tests had a separate desktop-interference bug: most fixtures
showed real floating windows, many tests ended while mock capture remained
active, and teardown did not hide those panels. Replaying the old 56-case flow
class in the private native host passed in **13.579s**, while a window-server
sampler counted **22 test-owned panels at exactly the same position**. Stacked
tall and compact dark surfaces can cover the rosette as shown in the supplied
image. The screenshot itself does not preserve window ownership, so its precise
owner cannot be identified retroactively; the overlapping-test-window mechanism
is directly reproduced.

The containment is test-only. Ordinary flow fixtures hide floating controls;
the explicit visibility test still verifies native show/hide while parking its
panel offscreen in the same main-actor turn. Per-case cleanup hides only this
XCTest process's pill panels. Opt-in visual acceptance retains the actual
on-screen controller and always hides it afterward. No production flower art,
colors, rotation, audio response, completion flourish or Reduce Motion changed.

## Separate panel-layout repair

The initial quiet recording also exposed a distinct panel jump. Company/project
rows appeared after capture started, shifting the Notes flower by roughly
seventy points. The coordinator now declares that section before presenting
the panel. Shared inactive rows reserve the same geometry until values load.
Capture and metadata ordering are unchanged; a panel without company support
keeps its original layout, and reset clears the section flag.

## Verification

The main focused run passed **105 cases, one opt-in native-control skip,
zero failures**, in **11.861s**, following a **14.65s** incremental build. The
real 360/420-point panel at its 460-point initial height keeps the Notes flower
and editor identity and rectangles within half a point through loading and
Recording. Rotation and breathing remain attached. A blocked-capture flow test
proves the slot exists before capture returns. Existing pill re-entry,
paused/Reduce Motion and legacy-layout checks pass.

The task's one full-suite run passed **8,718 XCTest cases, 38 skipped, zero
failures**, in **481.678s**. Swift Testing passed **30 cases in three suites**.
It covers the shipped app change at `a1d58bb31a89`; the later opt-in diagnostic
fixture and test-only desktop containment have separate verification and do not
retroactively alter that source-qualified count. The suite was not repeated.

The initial new test helper needed explicit `self` for its recursive lazy view
search. The containment fixture also needed Swift initializer argument ordering
corrected. Both were test-only compilation fixes. Strict formatting/whitespace
and independent review found no remaining production must-fix finding. Local
no-mistakes and Greptile executables are unavailable.

After containment, **106 focused cases, two opt-in native skips, zero failures**
passed in **15.384s**. The separate corrected native flow run passed all **56
cases**, zero skips/failures, in **13.131s**. A 20-second window-server sampler
covering that run found **zero on-screen test pill windows in all 200 samples**,
versus 22 at the same coordinates before containment. The explicit visibility
assertions remain enabled and passed; no case was skipped to hide interference.

Signed Release **`a1d58bb31a89`**, built **`2026-11-02T19:11:33Z`**, is installed
and running on Meetings with Start available. The flower renderer is unchanged
from the original app. Both installed app signatures pass deep/strict checks,
and no permission/sign-in reset was needed. Subsequent changes are tests/docs
only. The private native helper was stopped after every run.

The final read-only comparison preserves every pre-existing column of all
**21 baseline transcription rows**, the existing project/preparation, six
project memberships and eight original recording associations. Two additional
QA recordings and their associations remain, with QA titles. All **23 recording
paths and 23 meeting-artifact folders exist**. Database integrity is `ok`, with
zero foreign-key violations. Saved preferences/style and the original app's
executable fingerprints are unchanged. No original meeting or artifact was
deleted.
No multi-hour capture guarantee is claimed. Private source audio, calendar
identities, screenshot/window-owner dumps and settings remain outside the repo.
