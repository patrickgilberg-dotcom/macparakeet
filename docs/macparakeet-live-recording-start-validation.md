# Recording-start layout in Live

## Reproduced behavior

The installed original is MacParakeet 0.8.10, source `394e630b4af7`.
Live's recording tile, floating pill controller, Merkaba renderer and flower
animation code match that source. The fork adds company/project controls to
the recording panel after capture starts. In the installed `571fa9bc26bc`
build, a quiet start showed no organization section during Starting; its later
insertion moved the Notes flower downward by roughly seventy points. The
recording was stopped normally and retained with a QA title.

## Change

The coordinator declares organization-control availability before presenting
the panel. A shared row layout occupies the section during Starting, with
inactive placeholder values, then becomes the real controls. It does not wait
for metadata or change capture, storage, project selection, artwork, colors,
rotation, audio response, or Reduce Motion. A panel without company support
keeps its original layout. Reset clears the availability flag.

## Qualification

The final focused run passed **105 cases, one opt-in native-control skip,
zero failures**, in **11.861s**, following a **14.65s** incremental build. It
includes the real 360/420-point panel at its 460-point initial height: the
Notes flower and editor keep their identity and rectangles (within half a
point) while organization loads and state becomes Recording. Rotation and
breathing remain attached. A blocked-capture flow test proves the slot exists
before capture returns; reset and the legacy path are covered. Existing pill
re-entry and Reduce Motion/paused flower checks also pass.

The initial test compilation caught an explicit-self requirement in the new
test's recursive view search; that test-only helper was corrected. Strict
formatting and whitespace checks pass. Independent review found no must-fix
issue. Local no-mistakes and Greptile executables are unavailable.

Signed installation and the corrected-build native startup check remain pending.
The earlier company-organization full-suite result predates this change and
is not represented as its verification. No multi-hour capture guarantee is
claimed. Private source audio, calendar identities and settings are excluded.
