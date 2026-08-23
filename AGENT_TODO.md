# Score app — agent checklist

This file is the durable hand-off checklist for the project. Keep it current as
work lands; do not infer completion from a prototype screenshot.

Current release gate: finish and verify the native macOS build first. Wasm and
iOS remain later portability targets and must not distract from native quality.

## Current correction and immediate musical gate (2026-08-23)

- [x] Correct the private score and live transport to **quarter-note = 147**.
  The earlier eighth=147 / 73.5-quarter-QPM interpretation was wrong and made
  playback half-speed. A Zig regression prevents this private-score failure
  mode from returning.
- [x] Reject the first synthetic 6/4 piano-opening candidate after native
  sampler audition. Although it was denser, it overused B-flat and introduced
  droning bass octaves from bar one; its 66.7% recording pitch-class gate and
  the audible result both fail professional fidelity. It was never promoted
  over the ignored canonical private MXL.
- [x] Generate and hot-load a second recording-led 6/4 opening candidate. The
  first three bars now keep the left hand silent as supported by the supplied
  notation and retained accompaniment, and the right-hand cell centers the
  opening D-flat/A-flat/F evidence instead of mechanically repeating B-flat.
  The 80-beat / 32.653-second opening renders through the real 1,704-region
  sampler with 192 piano attacks, 14 continuous pedal events, -16.21 dBFS peak,
  and zero overloads. Exact-pitch agreement improves 26.4% -> 39.1% and
  pitch-class agreement improves 66.7% -> 75.5%; this is meaningful progress,
  not certification.
- [x] Restore the expressive opening after a hot-host rebuild exposed two
  separate regressions: the host had recovered an older 193-measure autosave
  with zero pedal events, and MusicXML export/re-import collapsed continuous
  performed velocities into coarse dynamic markings. The unpromoted v10
  candidate now carries standard `<sound dynamics>` values through the Zig
  importer/exporter (37 distinct MIDI levels, 52..93 over the opening), keeps
  all 14 CC64 pedal events at a recording-gated 72/127 depth, and renders 192
  attacks / 32.653 seconds through the 1,704-region grand at -17.66 dBFS with
  zero overloads. Debug `load` now writes the atomic autosave immediately,
  closing the rebuild race.
- [x] Add `compare-performance` to the consolidated Zig workbench and gate the
  expressive candidate against the retained audio, not against subjective
  loudness alone. Relative to the former flat-velocity v8 render, v10 improves
  normalized envelope correlation 0.311 -> 0.546, attack correlation 0.294 ->
  0.535, sustain correlation 0.660 -> 0.665, onset precision 0.690 -> 0.702,
  and normalized envelope error 0.309 -> 0.241. A 54/64/72/80/96 pedal sweep
  selected the shallowest full-sustain winner (72); all alternatives remain
  ignored review artifacts. The v10 candidate SHA-256 is
  `772402f9eb3d5183949f5d074e27579c680968de6c89e29764960bbd9b4fdf68`.
  A live autosave recovery followed by native MXL export re-imports with the
  same 195 measures, 2,760 events, 37 instrumental velocity levels (52..93),
  14 pedal events, and 56.693% MusicXML damper depth.
- [x] Rebase the complete 193-measure recording ledger onto the v10/v11
  195-measure timeline instead of stretching a rigid 147-QPM clock across the
  recording. New measures 1..14 cover 0..32.653 seconds; canonical measure 13
  resumes as target measure 15 at 33.250 seconds with a 0.597-second transition;
  all remaining measures map one-to-one through target measure 195. The
  anchor-aware Zig shaper then assigns continuous performance velocity to the
  remaining 1,473 attacks without changing notes, rests, lyrics, voice guide,
  harmony, fingering, articulation, or pedal data.
- [x] Accept the unpromoted full-performance v11 candidate over v10 on the
  anchored 195-measure render gate. Envelope correlation improves 0.243 ->
  0.718, attack correlation 0.233 -> 0.697, sustain correlation 0.192 -> 0.666,
  normalized envelope error falls 0.310 -> 0.179, and onset precision improves
  0.669 -> 0.676. The 322.449-second / 1,665-note render peaks at -16.58 dBFS
  with all 14 pedal events and zero overloads. Measures 1..14 remain byte-level
  equivalent in exported notation/performance content; the first difference is
  measure 15. Native autosave recovery/export preserves 195 measures, 2,760
  events, 40 velocity levels (52..94), and 14 pedal events. Candidate SHA-256:
  `9eb1f6b0b2e690cee4b428cf81163774a09d0fbb9027bed297045c178d2a1878`.
- [x] Add an anchor-aware, per-measure multi-stem pitch audit and use it to
  repair target measure 107 without altering rhythm, dynamics, articulation,
  lyrics, or pedal data. The stale C/A-flat/E-flat cell scored only 10% exact
  and 20% pitch-class agreement in that measure; the v12 D-flat/A-flat/F to
  G-flat transition scores 80% exact and 90% pitch-class agreement at the same
  attacks. A pitch-preserving hand redistribution keeps the correction within
  a one-octave maximum hand span. Across the full score, the same three-source
  120 ms gate improves exact matches 1,070 -> 1,077, pitch-class matches
  1,431 -> 1,438, corroborated exact 394 -> 396, and corroborated pitch class
  882 -> 886. Native Dawn/Metal hot-load, sampled playback, the 322.449-second
  render, and the 1,704-region sampler pass with all 40 velocity levels, all 14
  pedal events, and zero drops/overloads. This remains an ignored private v12
  candidate pending a pianist/ear gate, not a published authoritative score.
- [x] Correct target measure 99's octave/voicing mismatch without changing its
  rhythm: the former high G-flat3/D-flat5/A-flat5 loop had 0/8 exact and 5/8
  pitch-class matches, while the retained guitar/accompaniment evidence carries
  a low G-flat2 foundation under F4/A-flat4 then D-flat4/F4. Private v13 reaches
  8/8 exact and pitch-class matches locally and raises the full-score totals to
  1,085 exact and 1,441 pitch-class matches. The complete render improves v12's
  envelope/attack/sustain correlations 0.718134/0.698165/0.665215 to
  0.719289/0.699302/0.668347 and reduces normalized error 0.179165 -> 0.178189.
  Native hot-load, a controlled three-second 147-QPM playback, GPU capture,
  autosave/export round trip, and mechanical playability pass with 40 velocity
  levels, 14 pedal events, and zero sampler faults. SHA-256:
  `14c3f2f471beb5488cea84229c4caa0f3af5ddde600f2b2a3dea083c75e3a4c4`.
  Evidence is mainly the separated guitar stem, so pianist/ear approval remains
  mandatory despite the non-regressing quantitative gate.
- [x] Reject the first target-measure-92 retuning despite strong local pitch
  evidence. Its A-flat2/E-flat4/C4/E-flat4 transition improves the measure from
  0/4 to 4/4 exact matches (three corroborated), but the complete render lowers
  envelope/sustain correlation from v13's 0.719289/0.668347 to
  0.716907/0.663048. An anchor-shaped velocity retry recovers attack correlation
  to 0.699482 but still regresses envelope/sustain to 0.717720/0.663361, so v13
  stays canonical and hot-loaded. Keep the ignored v14 reports as rejection
  provenance; do not promote local detector agreement over whole-phrase sound.
- [x] Make authored MusicXML `change` pedals perform a real ordered CC64 lift
  and redepress in both live playback and the offline sampler. The former path
  resent only the nonzero value, so its visible repedal marks did not operate
  the dampers. Preserve v13's accepted pedal plan and add only the missing
  terminal lift: private v15 round-trips as 195 measures, 2,760 events, 40
  instrumental velocity levels, and 15 pedal events. Under the corrected
  semantics its complete 322.449-second render exactly preserves the fresh
  v13 baseline metrics (0.684191 envelope, 0.587277 attack, 0.687069 sustain,
  0.185801 normalized error), peaks at -3.86 dBFS, and reports zero overloads.
  It is now the ignored `Holocene-private-study.mxl` canonical file, byte-equal
  to the live export, with SHA-256
  `9d31da3d2f1b809c2e390696e53226ebd0e9bf922e2edc2bddefbbaf3016324d`.
  Reject the automatic 96-, 196-, and 222-event pedal candidates because their
  frequent damper changes materially regress the complete envelope/sustain;
  keep them only as ignored negative provenance.
- [x] Prevent stale development windows from restoring an older score after a
  host rebuild. Only the Debug process that owns `/tmp/score-dev-<uid>.sock`
  may write `autosave-dev.score`; duplicate comparison windows are read-only
  for that journal. After closing the two stale 193-measure hosts, cold-start
  QA without an explicit score recovered v15 at exactly 195 measures / 2,760
  events / 75 harmonies / 15 pedals, followed by a clean Dawn/Metal capture
  and zero sampler drops or overloads.
- [x] Extend the per-measure Zig audit with source-by-source active pitch lists
  and investigate the next two weakest bars without guessing. Measure 64 is
  deferred because the supplied page marks the corresponding harp bar empty
  while the recording contains accompaniment, and the three separators do not
  agree on a single replacement voicing. At target measure 137, supplied-page
  OMR plus the recording support an F3 and lower D-flat register correction;
  the six-note v16 candidate improves full exact/corroborated totals by four
  and local pitch-class agreement from 6/8 to 8/8. Both unchanged and locally
  reshaped velocities nevertheless regress complete-render envelope/attack
  correlation, so v16 remains ignored rejection/review provenance and v15
  stayed canonical through that rejected trial.
- [x] Promote a narrowly scoped, recording-led measure-174 correction as
  private v17. At beat 702, three separated sources agree on the low A-flat2
  foundation and support the E-flat4/A-flat4/D-flat5 playable right-hand
  voicing over the former unsupported B-flat4/F5 shell. The three retuned
  pitches preserve every onset, duration, velocity, articulation, lyric,
  fingering, harmony, and pedal event; full evidence improves 1,085 -> 1,088
  exact and 1,441 -> 1,443 pitch-class matches. A first two-note variant was
  rejected for creating a 14-semitone right-hand span; v17 passes with no
  over-octave spans. Against a freshly rerun same-reference v15 baseline, the
  complete sampled render improves envelope 0.683432 -> 0.685471, attack
  0.585911 -> 0.587140, sustain 0.685043 -> 0.688738, and normalized error
  0.185807 -> 0.185337. Onset matches remain 790 while one extra detected
  candidate onset lowers precision by 0.000535; retain that caveat for the ear
  gate. Native sampled playback, GPU engraving, exact MXL export/re-import,
  system/WGSL reload, and 1,704-region sampler telemetry pass with zero faults.
  This accepted intermediate v17 SHA-256 is
  `77ade1f49911291aa5f97ae75f73fc0bd3371e1062f71ecc7ff730a3217e2d22`.
- [x] Promote the exact repeated-phrase correction at measures 38 and 55 as
  private v18. Both phrases formerly ended on E-flat4; at the corresponding
  authored onsets, two different separated-source pairs independently detect
  F4. Retuning only those two pitch nodes raises full evidence from v17's
  1,088/1,443 exact/pitch-class and 397/888 corroborated matches to
  1,090/1,445 and 399/890. Against v17, the complete sampled render improves
  envelope 0.685471 -> 0.686662, attack 0.587140 -> 0.587878, sustain
  0.688738 -> 0.690823, normalized error 0.185337 -> 0.185066, and matched
  onsets 790 -> 791. Both live phrase auditions, both GPU pages, exact MXL
  export/re-import, mechanical playability, and sampler telemetry pass. The
  ignored canonical SHA-256 is
  `924edd2d067936a0c4255c4c3e5fa4076d7d813cd1ef4102fb9567df123e0a2c`.
- [x] Remove the two same-voice duplicate piano notes at measure 62 as private
  v19. B-flat4 and D-flat5 at beat 264 were literal duplicate MusicXML chord
  nodes, not unisons in independent voices. Extend the single Zig workbench's
  playability gate to report this defect and add a conservative `dedupe`
  transform that touches only semantically identical instrumental copies;
  tests prove separate voices and the vocal guide survive. The result passes
  mechanical playability with 195 measures, 2,758 events, 2,018 pitches,
  1,663 instrumental notes, 485 vocal-guide notes, 75 harmonies, 15 pedal
  events, and quarter-note = 147. Full three-source exact/pitch-class rates
  improve slightly to 65.48%/86.83%; its complete 322.449-second Salamander
  render remains clean at -3.86 dBFS and rounded recording-performance metrics
  are unchanged. Native measure-62 audition, GPU engraving, system/WGSL hot
  reload, zero-fault sampler telemetry, and byte-identical live export pass.
  The ignored canonical SHA-256 is
  `8f4e0d9efdcbf59207912031b7a224b6726b8728603ded3e7657c4f825f574bd`.
- [x] Make incomplete pedal interpretation measurable instead of hiding it
  behind technical playability. The consolidated Zig report now distinguishes
  40 performed velocity layers (52..94) from two visible dynamic glyphs and
  reports pedal starts/changes/stops, active restarts, refresh gaps, and gaps
  beyond 16 quarter notes. Canonical v19 exposes one active restart and one
  713.99-beat gap, so publication remains `REVIEW_REQUIRED`.
- [x] Reject naive bounded-repedal v20 candidates. A tested Zig-only transform
  preserves the opening performance, normalizes the active restart, and adds
  pedal changes only on real attacks after 8-, 12-, or 16-beat gaps. All full
  renders are clean, but the best 12-beat candidate regresses envelope
  0.687406 -> 0.644380, sustain 0.692831 -> 0.572780, normalized error
  0.185055 -> 0.205943, and candidate onsets 1,215 -> 328. Keep all three
  ignored as rejection provenance and leave v19 canonical. Next pedaling work
  must use phrase/harmony boundaries plus a real ear/piano gate rather than a
  fixed timer.
- [x] Stop the native pedal guide from teaching an unreviewed 713.99-beat hold
  as though it were authoritative. The GPU footer now replaces a next-event
  countdown with `PEDAL PLAN REVIEW / LONG HOLD` whenever sustain is active
  and no refresh occurs within 16 quarter notes. A focused core test and live
  beat-262 systems/WGSL hot reload verify the warning; canonical audio and MXL
  remain unchanged.
- [x] Reject the first harmony-aware v21 pedal candidate and identify its data
  prerequisite. The Zig transform changes pedal only at a different authored
  harmony and a real piano attack, but nearly every post-opening label through
  measure 91 is B-flat minor seventh and the harmony map ends there. The three-
  change min-4 candidate is clean but regresses envelope 0.687406 -> 0.676200,
  attack 0.589182 -> 0.569262, sustain 0.692831 -> 0.680762, normalized error
  0.185055 -> 0.188025, and matches 837 -> 801. Keep v21 ignored and v19
  canonical. Build a recording/page-supported complete harmony map before the
  next phrase-aware pedaling attempt.
- [x] Clarify the live count-in readout as `N BEATS LEFT` (with a singular
  one-beat form). The transport already used the real current meter—one 6/4
  bar in the private score—but the former transient `2 BEATS` screenshot could
  be mistaken for the configured count-in length. A focused Zig test and live
  Dawn/Metal capture verify the new wording during the same stateful hot reload.
- [ ] Complete the ear-and-pianist gate for the second opening candidate before
  promotion. Refine its attack contour, voicing, hand assignment, velocity,
  articulation, and pedal against the retained recording. Keep the canonical
  private MXL unchanged until the musical result—not only a detector metric—is
  accepted.
- [x] Replace the sparse opening treble with the user's richer 42-quarter-beat
  D-flat fragment while preserving the recording-reviewed bass, independent
  vocal guide, lyrics, all 193 authored measures, and quarter=147 timing. Direct
  retained guitar/piano/other transcription evidence raises exact opening
  matches from 55 to 71 and pitch-class matches from 68 to 83. The competing
  fragment-bass replacement added no exact matches and was rejected.
- [x] Load the promoted ignored MXL in the live native Dawn/Metal app, verify
  193 measures / 2,640 imported events, render the denser beamed opening, move
  chord symbols out of the page-header lane, and confirm the 1,704-region grand
  sampler reports zero drops/overloads at 1/4=147.
- [x] Extend the accepted fragment only into structurally exact repetitions
  already present in the score (63 non-overlapping replacements through beat
  346), producing 2,706 events / 1,904 pitched notes / 67 harmony events. On
  beats 42..346, anchored stem-event exact agreement improves 367/544 to
  428/609 and pitch-class agreement improves 437/544 to 513/609; independent
  frame evidence improves 162 to 183 exact and 353 to 423 pitch-class matches.
  The promoted private MXL re-imports at quarter=147, validates as an archive,
  and renders on native GPU pages 1 and 2 without the former header overlap.
- [x] Promote a narrowly scoped recording-backed enrichment for measures
  90-97. Seven corroborated empty-slot attacks raise anchored stem agreement
  from 19/48 to 26/55 exact and 40/48 to 47/55 pitch-class; the independent
  accompaniment-frame gate also improves from 8/48 to 11/55 exact and 27/48
  to 31/55 pitch-class. Native GPU engraving is collision-free, q=147 live
  playback advances 9.89 quarter beats in four seconds, and the 1,704-region
  sampler reports zero drops/overloads.
- [x] Promote the next independently non-regressing enrichment for measures
  106-113. Thirteen corroborated empty-slot attacks raise anchored stem
  agreement from 37/73 to 50/86 exact and 52/73 to 65/86 pitch-class;
  independent accompaniment frames improve from 19/73 to 24/86 exact and
  42/73 to 50/86 pitch-class. Generated pitches now use the document key's
  enharmonic spelling, removing an unprofessional F-sharp glyph in this
  five-flat score. Native engraving, timed playback, archive import, and
  sampler telemetry pass.
- [x] Promote the clean, key-spelled measures 147-154 enrichment. Eight
  corroborated attacks, split evenly between treble and bass, raise anchored
  stem agreement from 37/83 to 45/91 exact and 72/83 to 80/91 pitch-class;
  the independent accompaniment-frame gate also improves from 20/83 to 22/91
  exact and 58/83 to 64/91 pitch-class. Native GPU engraving, q=147 timed
  playback, archive validation, and sampler telemetry pass. The canonical
  ignored MXL now contains 2,739 events / 1,933 pitched notes / 483 separate
  vocal-guide events.
- [x] Add a consolidated Zig playability gate and use it to repair the only
  two over-octave single-hand attacks: measure 106's B-flat3 is assigned to
  the right hand while G-flat2 remains in the left, preserving pitch and
  timing but reducing the maximum one-hand span from a major tenth to one
  octave. The score now passes its mechanical piano-range, duration, chord
  size, attack-rate, hand-span, and same-voice duplicate gates; multiply
  escaped apostrophes in two
  singer-guide words are repaired during the same MusicXML round trip. The
  canonical private SHA-256 is
  `39fc2d9234db1553aca62dfaf54544fb74408da5393586dbd8800c7b14a8f720`.
- [x] Reject evidence-generated candidates that merely add density. The dense
  measures 98-114 variant collided with authored notation; its conservative
  successor regressed independent exact/pitch-class ratios. The measures
  187-end variant improved exact matches but reduced independent pitch-class
  precision. None was promoted.
- [ ] Extend recording-backed professional piano reduction work beyond the
  opening. The remaining measures are not yet certified as a concert-quality
  reduction; preserve candidate/rejection evidence and require a musician pass.
- [ ] Author recording-faithful dynamics, articulation, and sustain-pedal
  transitions across the complete canonical score. The opening v10 candidate
  now has audio-shaped continuous velocities and 14 pedal events, but the
  canonical score and later sections still lack a complete musician-approved
  interpretation; mechanical playability must not be confused with publication
  readiness or professional interpretive completion.
- [ ] Rerun every historical musical playback/recording QA item below that says
  eighth=147 or 73.5 QPM. Those timing claims are superseded and do **not** count
  as current completion evidence.
- [x] Consolidate the former script sprawl into exactly three Zig tool sources:
  `score_workbench.zig` for inspect/enrich/repeat/CSV/audio evidence,
  `sampler_workbench.zig` for render/quality gates, and `dev_control.zig` for
  the live Debug socket. Remove all 41 Python files from `scripts/` into an
  ignored recoverable archive; add no new Python pipeline.
- [x] Make the consolidated sampler quality gate deterministic for streamed
  release/hammer regions and repedaling by establishing controller state and
  priming streamed tails before measurement. Two consecutive ReleaseFast
  passes cover the 1,704-region / 641-preload Accurate Salamander grand,
  velocity layers, sampled release, hammer/pedal noise, pedal resonance,
  half/full pedal, repedaling, replay stability, and zero drops/overloads.
- [x] Keep offline audio evidence reliable in Debug builds by heap-allocating
  the large fixed-capacity import report; the full 5:32 accompaniment WAV plus
  private MXL now analyzes without the former Debug stack crash.

## Non-negotiable architecture

- [x] Zig core using Flecs for component storage, systems, queries, and events.
- [x] GPU packet rendered with WebGPU/Dawn on macOS and WebGPU in browsers.
- [x] Metal renderer on iOS consumes the same packet ABI.
- [x] No Canvas 2D, WebGL, or software-rendering fallback.
- [x] Platform code is limited to window/surface, audio, MIDI, microphone,
  accessibility, file picker, and lifecycle bridges.
- [x] Swift is only the thin iOS platform bridge; it does not own app UI or
  product state.
- [x] Debug systems and screen-composition module hot-reload while preserving
  the live Flecs world; release builds link the same code into one binary.
- [x] Hash the generated glyph atlas in the hot-module ABI. Reject a module
  whose UV metadata does not match the host texture, and rebuild/relaunch the
  native host for atlas, ABI, shader, renderer, audio, or other GPU-resource
  edits. This prevents corrupted text and music during development.
- [x] Add a Debug-only local `score-devctl` channel polled at the native frame
  boundary. It can load a score, inspect state, control transport/tempo/UI,
  navigate authored score pages,
  force reload, inspect sampler regions/queue/overload telemetry, inject MIDI
  into both Flecs/practice state and the real sampler, and invoke a command hook
  compiled into the hot Zig dylib; release builds do not start the socket.
  Verify rebuild/reload preserves the imported document, cursor, and UI state.
- [x] Expose loop enable/range in live state and disable a stale active loop
  when a Debug seek leaves its bounds, preventing the next frame from wrapping
  to an unrelated bar and masquerading as incorrect tempo progression.
- [x] Prevent a second Debug instance from unlinking and stealing a live
  `score-devctl` Unix socket. Probe a failed bind, reject a live owner with
  `SocketInUse`, and unlink/rebind only a stale socket; a native unit test owns
  two server attempts against an isolated per-test path.
- [x] Hot-reload native WGSL pipeline edits through Dawn with asynchronous
  validation, exact diagnostics, and last-good pipeline retention. Prove both
  invalid WGSL and a missing entry point keep the PID, Flecs world, and rendered
  frame alive; expose `shader reload|state` through `score-devctl`.
- [ ] Add the equivalent development-time last-good Metal shader reload path to
  the deferred iOS host after the native release gate clears.
- [x] Prove hot reload interactively without losing imported score, transport,
  annotation, or current practice take.
- [x] Keep score authoring/inspection/evidence operations in the single tested
  Zig `score-workbench`; `scripts/` is limited to thin platform build, package,
  development, and authorized capture wrappers. Private evidence, generated
  candidates/reports, captures, and scratch files stay ignored.

## Notation and visual quality

- [x] Shared Inter + Bravura MTSDF atlas on every GPU backend.
- [x] UTF-8 decoding and Latin-1 UI glyphs.
- [x] Real SMuFL clefs, time-signature digits, noteheads, stems, flags, and
  ledger lines.
- [x] Add the Bravura/SMuFL piano brace to the shared MTSDF atlas and size it
  from its generated plane bounds so every GPU-rendered grand staff is joined
  cleanly at desktop and overview zoom. Real Dawn/Metal readback confirms both
  page systems use the brace without touching the analytic staff connector.
- [x] Render clef-aware key signatures with up to seven SMuFL flats or sharps
  on both staves and reserve engraving space before the meter/music origin.
- [x] Import semantic MusicXML `<harmony>` events (root/kind/display text,
  slash bass, inversion, and offset), persist them in portable `.score` v11,
  render chord symbols with SMuFL accidentals, and export/re-import them.
- [x] Separate engraving anchors for staff, clef, meter, notes, barlines, and
  playback cursor.
- [x] Reserve a dedicated left inset after every mid-system meter change on
  both piano staves and the optional vocal guide. Use the same inset in score
  hit-testing so a 2/4-to-4/4 change cannot overlap the first note/rest and
  pointer-to-beat mapping remains reversible. A native Dawn/Metal page-1
  readback at the private score's real meter transition and a focused Zig
  regression test pass.
- [x] Import, render, export, and re-import beams, explicit rests, dots, note
  accidentals/naturals, ties, basic slurs, articulations, dynamics, and tuplets.
- [ ] Finish professional optical engraving: multi-voice collision resolution,
  numbered/overlapping and cross-system slurs, expression collision avoidance,
  beam/tuplet edge cases, and complete SMuFL coverage.
- [x] Replace the fixed two-system demo with measure-aware horizontal spacing
  and complete-measure system breaks. Short final pages render only populated
  systems instead of a phantom empty grand staff.
- [x] Present the score as discrete paper pages with authored-measure system
  breaks, `PAGE N / total`, visible edge turn controls, trackpad/mouse-wheel
  page turns, Left/Right and PageUp/PageDown keys, playback-follow page turns,
  and accessible Previous/Next Page actions. Keep edit-mode Left/Right reserved
  for note timing adjustments.
- [x] Make native pagination height-aware across rendering, playback follow,
  page counts, scrolling, selection, and editing. Constrained windows show one
  complete voice-plus-piano system instead of painting a second system below
  the paper or into the keyboard.
- [x] Replace the remaining two-system ceiling with responsive one-to-six
  system pages, vertically justify every complete system, and share the same
  page map across rendering, page counts, turns, playback following, note
  selection/insertion, and score-space ink hit-testing. Focused Zig tests cover
  six piano systems and five voice-plus-piano systems. Real Dawn/Metal readback
  passes with four piano systems and three independent voice-plus-piano systems
  in a 1400x1100 window; next/previous preserve authored measure boundaries.
- [x] Add GPU controls, hot keys, accessibility actions, and Debug socket
  commands for paged, continuous-system, two-page spread, score zoom, and
  distraction-free focus modes. Navigation advances one system in continuous
  mode, one page in paged mode, and one spread in two-page mode.
- [x] Make score zoom control actual reading density. In paged mode, reflow
  complete authored measures and successively merge additional complete score
  systems onto the same paper sheet; never reveal a second sheet below or turn
  paged mode into a spread. Use the same zoom-aware page map for GPU drawing,
  playback following, turns, continuous navigation, annotations, selection,
  and editing. With the piano and vocal guide visible in the native 1440x900
  app, real Dawn/Metal QA shows one system at 100%, two on the same page at
  65%, and four on the same page at 45%.
- [x] Anchor all newly authored ink to absolute score beat and normalized
  system height so it follows the same music across zoom, keyboard visibility,
  and responsive one-to-six-system pagination. Preserve legacy page-relative strokes in
  `.score` v15, regression-test persistence and reflow, and expose removable
  Debug `ink dot` marks for native framebuffer QA. Real Dawn/Metal readbacks
  confirm beat 10 moves from the second system on page 1 to the only system on
  page 2 when the guided piano changes the available page height.
- [x] Export the complete authored score—not merely the visible page—as a
  paginated A4 PDF from the existing Export panel. Render each page through the
  native Dawn/Metal engraving path, omit application chrome and playback
  highlights, preserve normal spacing on a short final page, and validate an
  18-page artifact by rendering its first, middle, and final pages.
- [ ] Add free pan and part selection.
- [x] Add Debug-only readback of the real native Dawn/Metal framebuffer through
  `score-devctl capture`; use it for deterministic GPU visual regression. The
  command requires a `.bmp` path so the artifact's extension matches the actual
  top-down BGRA bitmap encoding.
- [x] Run repeated native Dawn/Metal visual QA at desktop and the minimum
  720x540 window, including page turns, keyboard-visible one-system layout,
  keyboard-hidden multi-system layout, compact controls, and meter changes.
- [ ] Perform the deferred iPad visual/input pass after native is release-ready.

## Guided piano

- [x] Toggleable five-octave GPU-rendered virtual piano.
- [x] Score-synchronized current and next key highlights for left/right hands.
- [x] Compact current/next finger-number markers aligned to exact keys.
- [x] Click/touch keys to audition through the native/Web audio engine.
- [x] Improve the compact current/next fingering guide with an allocation-free,
  phrase-aware dynamic program over a 24-attack window. It models hand
  direction/span, thumb-under and finger-over crossings, repeated notes, large
  reaches, phrase gaps, and black-key ergonomics; separates hands by score
  staff and excludes rests and vocal-guide cues. Native Dawn/Metal QA proved
  the guide follows playback and survives Flecs/WGSL reload without losing the
  cursor.
- [x] Add complete playable chord fingering to the virtual piano. Exhaustively
  assign distinct fingers to every simultaneous one-to-five-note hand voicing,
  mirror left/right ordering, preserve phrase-anchor continuity, avoid
  unnecessary black-key thumbs, color every current/next chord key, expose the
  exact result through `fingering chord`, and visibly flag >5-note hand clusters
  for redistribution rather than pretending they are playable.
- [x] Add musician-authored fingering overrides as standard score-note
  semantics. Import/export MusicXML `<technical><fingering>`, persist it in
  backward-readable native `.score` v15 without exceeding the 32-byte Flecs
  note budget, feed it into exact phrase/chord key guidance, support undo/redo,
  set/clear it with Edit-mode `1`...`5`/`0`, and expose
  `fingering set NOTE_ID 1..5|clear` through the live development socket.

## Score library and content

- [x] Remove all hard-coded Holocene/Bon Iver branding from the app UI.
- [x] General offline Score Library modal.
- [x] Bundle Bach Minuet in G (public-domain engraving) and Beethoven Für Elise
  (OpenScore CC0), with sources, rights statements, and SHA-256 records.
- [ ] Add more compact, well-engraved CC0/public-domain piano starters after
  verifying the rights of each specific digital edition/arrangement.
- [x] Generate a private, gitignored two-part MXL draft from all 12 supplied
  score pages and prove that the native importer accepts its initial 1,874
  events; source-page repairs through the two omitted cadence chords plus six
  recording-led reduction repairs bring the 174-measure page-derived core to
  2,348 notation events after four recording-gated independent-page rest
  recoveries. The independently anchored final refrain repeat extends the
  private full-recording study score to 193 measures / 2,564 events; the later
  dual-reference measure-94 repair brings the current file to 2,575 events.
- [x] Emit `local-content/holocene/Holocene-private-study.mxl` as a standard
  compressed MusicXML container; verify title, native import, guided keyboard,
  and playback start/stop end-to-end. Preserve the supplied arrangement's
  quarter-note = 132 marking only as notation-source data. Encode the requested
  pulse as quarter-note = 147 (`sound tempo=147` quarter QPM). The former
  eighth-note/73.5 interpretation was an implementation error. Do not claim the generic
  onset analyzer independently proved it: finger-picking subdivisions produce
  octave/phase-confused candidates ranging from 74 through 167 depending on
  window and prior. A recording/score-aligned variable tempo map remains a
  mandatory unfinished gate.
- [x] Correct the private draft from the supplied C-major page source into the
  recording's D-flat-major concert key (five flats, one semitone higher),
  including the independent vocal guide. The ignored recording comparison
  improved from 39.45% to 65.26% pitch-class agreement and from 7.28% to
  25.56% exact-pitch agreement. Treat that large improvement as evidence for
  the key correction, not as certification of individual notes or voicings.
- [x] Generate ignored JSON/Markdown audit
  ledgers. After meter, full-rest, cross-staff contamination, and visible
  duration repairs, insert explicit MusicXML `<forward>` spans instead of
  inventing notes for unrecovered OMR time. The current 2,575-event extended
  draft passes the structural cursor audit with zero issues, while the source
  page's separate `REVIEW_REQUIRED` ledger retains 77 gaps across 62
  part/measures and 86 original Audiveris rhythm warnings; copied repeat bars
  inherit the corresponding musical-review status. Structural `PASS` is not
  musical accuracy and must never waive those review gates.
- [x] Restore the whole-note cadence chords visibly printed in P2 measures 37
  and 96 but omitted by the combined OMR pass. In recording key they are
  Gb3-Db4 / Db5-Ab5 and Db3 / Ab3-Db4 respectively. Measure 96 now reaches
  91.8% pitch-class and 70% bass agreement against its recording window;
  measure 37 reaches 90.1% pitch-class agreement but its bass remains an ear
  review item. Keep both recording statuses non-certifying.
- [x] Fully transcribe the visibly complete page-8 accompaniment in P2 measures
  98-114: alternating beamed eighth pairs, quarter rests, chord tones, voices,
  and staves. This removes 49 recognition gaps without extending the pattern
  beyond the supplied engraving. Generate a private part/measure
  source-review matrix.
- [x] Fully transcribe the complete page-9 piano accompaniment in P2 measures
  115-130. Recover the omitted second halves of measures 115-122 and 124-125,
  retain the changing voicings in measures 121-122, and restore the independent
  low E2 whole note in measure 123. This removes another 26 recognition gaps
  without extrapolating beyond the engraving. The 350-entry source-review
  matrix reached 33 page-complete entries at this checkpoint; all entries
  remain recording-unverified.
- [x] Fully transcribe the supplied page-10 piano accompaniment in P2 measures
  131-146, including the D/C right-hand cells, the corrected C4 bass arrivals
  in measures 136-137, the complete 2/4 measure 138, and the restored 4/4
  continuation through measure 146. Correct the supplied-page boundary map so
  measures 147 and 165 begin pages 11 and 12. The source-review matrix reached
  49 page-complete entries at this checkpoint; all entries remain
  recording-unverified.
- [x] Remove the 24-unit phantom OMR measure before the real measure 138 and
  renumber every following bar to the printed source numbers. Fully transcribe
  page-11 P2 measures 147-164: the closing C5-G5-C5 cell, the complete
  un-beamed G5/G5/C5/D5/C5 figure, and every F/C, A/A, and G/G bass quarter
  alternation. The 174-measure/2,180-event MXL round-trips through the native
  exporter exactly; 132 gaps remain across 91 part/measures. The 348-entry
  matrix now has 67 page-complete and 281 review-required entries, with zero
  recording-verified entries.
- [x] Fully transcribe the supplied final page-12 piano part in P2 measures
  165-174: six complete un-beamed right-hand figures with F/C and G/G bass
  quarter alternations, both A-C-E to F-A-C arpeggiated half-note cadence bars,
  their G/E and G/C bass motion, and the tied low E2 across the last two bars.
  The regenerated 174-measure MXL imports as 2,217 events at this checkpoint,
  passes the structural audit with zero issues, and retains 114 explicit OMR
  gaps across 83 part/measures. The 348-entry source matrix now has 77
  page-complete and 271
  review-required entries; recording verification remains zero.
- [x] Drive GPU score pagination, note spacing, barlines, cursor placement, and
  meter glyphs from the imported `Measure` map. Verify in a real native capture
  that measure 138 renders 2/4 on both staves and the following 4/4 return is
  retained, without beginning a displayed system inside an authored measure.
- [x] Move edit hit-testing, selection, annotation anchors, cursor following,
  seeking, and explicit page navigation onto the same imported-measure/system
  map as drawing. Exercise next/previous authored pages through both key input
  and the live `score-devctl page` command, including a real Metal capture of
  the private score's short final page.
- [x] Re-import the private MXL at its corrected quarter=147 pulse in the signed native app and
  visually verify GPU notation, guided keys, pedal indicators, and playback
  start/stop; keep the import warning visible while source/musical review is
  incomplete. Force systems and WGSL reload and capture a clean real Metal
  frame to prove the text/SMuFL atlas remains synchronized. Stress this with ten
  consecutive combined system/shader reloads; the post-reload GPU capture must
  remain clean, with the host-restart watcher and atlas-content ABI hash
  preventing the stale-UV corruption shown in the earlier screenshot.
- [ ] Finish a local, gitignored Holocene MusicXML/MXL with the official
  recording as the musical source of truth. The 12 supplied score pages are a
  secondary engraving/structure aid only: where they disagree with the heard
  pitch, rhythm, harmony, voicing, dynamics, articulation, pedal, or form, the
  recording wins. Never describe an OCR-derived draft as an accurate
  transcription.
- [x] Audit the user-supplied D-flat 6/4 piano fragment as an opening candidate
  against the accepted local recording evidence without promoting it. Its
  seven bars total 42 quarter beats, which is timing-plausible at eighth=147,
  but exact MusicXML review finds measures 1-3 overfilled, measure 7
  underfilled, and only measures 4-6 structurally complete. Recording review
  keeps all seven bars HIGH: the first three and partial seventh lack a left
  hand, while measures 4-6 have zero detected bass agreement. On the same
  35.5-second evidence crop, the fragment scores 0.311190 alignment cost versus
  0.272837 for the current two-hand measures 1-12. Retain the fragment as
  secondary texture/engraving evidence only; do not replace the opening until
  a rhythm-complete reconstruction beats both whole-mix and accompaniment
  gates and passes an ear/piano review.
- [x] Capture a private, gitignored recording reference from the user's
  authorized SoundCloud playback through BlackHole. Compose the main take, a
  clean retry anchored at 3:05, and a cadence-only take anchored at 5:11 into
  a 335.827-second evidence timeline: 1,330 of 1,344 quarter-second frames are
  covered through 5:32.7, with the last 14 fade/silence frames explicit. The
  take interrupted by an accidental pause and the autoplay-contaminated raw
  cadence take are explicitly excluded; only the trimmed clean derivative is
  accepted. A later verified-title 3:05 retry independently matches the clean
  overlap at 0.868 chroma similarity, but is retained only as corroboration
  because promoting it worsened the measure-audit queue. Keep every capture
  private and never redistribute it. A fresh post-unpause opening retry has no
  internal silence after its 12.62-second pre-roll and independently matches
  the accepted opening at 0.919838 chroma similarity with a 0.25-second offset.
  AVFoundation still ends that take at 298.494 seconds, so the duration gate
  correctly excludes it instead of pretending it covers the 5:35.827 track.
  The 2026-08-23 post-unpause redo is positively identified as Holocene by ASR,
  but its active signal stops at 74.65 seconds; four overlapping chunk retries
  and two explicit route-rebind probes are exactly -91 dBFS. Keep those attempts
  excluded and retain the already accepted split timeline plus the independently
  valid 4:20 tail as the evidence set.
  A second uninterrupted retry similarly ends at 297.459 seconds. Later
  diagnostics expose a hidden 30-second SoundCloud ad and a stale track stream
  near 1:26, while a real-opening routing probe records only -91 dBFS silence.
  A browser-controlled retry on 2026-08-23 verified the official player at
  0:00, remained visibly active through 5:33, and still produced only 287.505
  seconds through AVFoundation; its opening aligns to the accepted take at
  0.855510 chroma similarity with a 2.5-second content offset, so it is kept as
  corroborating review evidence and excluded from the authoritative timeline.
  A second 2026-08-23 redo used the visible SoundCloud control rather than the
  misleading accessibility play button. Its long body capture was rejected
  after fingerprinting and small-model ASR proved that the routed audio was
  not the accepted Holocene performance. A separately visible 4:20 seek did
  capture the late Holocene refrain continuously through the end; it overlaps
  the accepted 3:05 take at 0.842153 chroma similarity and is retained as
  independent tail evidence. Substituting that tail lowers global alignment
  cost from 0.280010 to 0.276901 but raises HIGH bars from 58 to 62 and anchor
  escapes from 2 to 3, so the formal gate rejects promotion and no score notes
  are changed from this retry alone.
  All are explicitly excluded; timestamp smoothing is rejected because it can
  fabricate nominal duration without restoring missing audible content.
- [x] Preserve the user-supplied D-flat/five-flat 6/4 fragment as ignored raw
  OMR evidence and prove native MXL import. Its seven OMR measures fail the
  structural audit (overfilled measures 1-3 and underfilled measure 7), so it
  is not an approved transcription or a basis for pattern-copying a full song.
  Use its chord labels/two-hand texture as secondary arrangement evidence only.
- [x] Create a separate ignored labeled fragment candidate that adds the five
  visible chord changes without altering the raw OMR. Native dev-control import
  reports 83 notes / 5 harmonies; its audit intentionally remains `FAIL` with
  four duration issues (measures 1-3 overfilled, measure 7 underfilled).
- [x] Build a section/timestamp verification ledger against the lawfully played
  official recording. It joins retained whole-mix and accompaniment audits,
  23 independent timing anchors, supplied-page provenance, and inherited-repeat
  mapping into 24 phrases / 193 measures. Every phrase has separate timing,
  recording-evidence, and source-page confidence plus explicit unresolved
  ambiguity categories. The current honest baseline has 74 strong dual-reference
  measures, seven MEDIUM and 17 LOW phrases, and all 24 remain `REVIEW_REQUIRED`.
- [ ] Resolve that ledger measure by measure: audit every meter, rhythm, pitch,
  accidental, tie, articulation, dynamic, lyric alignment, pedal event, and
  staff assignment against the recording, using the supplied pages only as
  secondary evidence. A section is not complete until the recording-led audit
  clears; never silently guess.
- [x] Add review-only monotonic word alignment for score-owned vocal directions
  and for an explicit page/system OCR lyric lane. The improved quiet-singing
  decode yields 220 private word candidates, versus 108 in the first pass;
  score-text and OCR timing anchors remain separate `REVIEW_REQUIRED` ledgers.
  They disagree in later sections and therefore must not author notes, measures,
  or a tempo map automatically.
- [x] Constrain the repetitive accompaniment DTW with the 17 score-text/page-OCR
  lyric anchors that independently agree. Piecewise timing centers plus a
  three-frame search band keep 15 anchors inside their named measure and the
  remaining two within 0.52 seconds, exposing stale candidate windows (most
  notably the previous measure-97 window, which was about twelve seconds late).
  The audit now penalizes an empty reduction over strong recording energy
  instead of perversely rewarding silence; regression tests cover both timing
  constraints and the silence objective.
- [x] Stitch the high-resolution independent-page OMR passes as secondary
  evidence with strict page/system counts. Audiveris 5.11.0 yielded 174 bars,
  527 voice events, and 1,822 piano events; the stitch ledger explicitly drops
  two shared 24/25-pixel non-pitched phantom slivers. The normalized candidate
  still fails 21 structural checks, carries 15 rhythm warnings, and creates 77
  high-priority recording-review bars despite a lower global alignment cost.
  It is therefore review evidence only, never a promoted score or completeness
  claim. The combined multi-page pass demonstrably dropped dense two-hand
  texture on later pages.
- [ ] Turn the supplied voice-and-harp source into an intentional professional
  two-hand piano reduction that preserves the instrumental texture and harmonic
  motion without doubling the sung melody. Keep that melody solely in the
  optional vocal guide, and document every octave, voicing, or playability
  change. Validate the reduction's musical result against the official recording,
  not merely against the supplied arrangement.
- [x] Preserve MusicXML lyric syllables/words as timed GPU-rendered text and
  round-trip them through MusicXML and portable `.score` documents.
- [x] Give lyrics a dedicated engraving lane below the optional VOICE staff,
  with a tested minimum clearance from its notation and the piano grand staff;
  when semantic per-note lyrics exist, suppress duplicate MusicXML direction
  phrases instead of painting both representations into that lane.
- [x] Tag named vocal parts/cue notes as an optional VOICE guide. Exclude guide
  pitches from piano playback, virtual-key fingering, and piano mistake scoring
  while retaining them as visible singer pitch cues; never fold them into the
  piano reduction silently.
- [ ] Complete the vocal guide's pitch/rhythm/lyric audit and add independent
  visible/audible controls plus singer range/transposition choices suitable for
  amateur and professional practice.
- [x] Import the corrected private file in the app and verify playback, cursor,
  guided keyboard, and both hand tracks end-to-end.

## Editing, practice, and capture

- [x] MusicXML, MXL, MIDI, and portable `.score` import.
- [x] MusicXML export with two-staff/voice structure, tempo, meter, key,
  chords, gaps, ties, explicit rests, tuplets, dynamics, slurs, articulations,
  and fermatas; regression-test export then re-import.
- [x] Preserve disjoint imported-part staff/voice tracks before projecting them
  onto MusicXML export parts. The playable reduction now exports as a braced
  two-staff Piano part and the optional singer material as a distinct labeled
  one-staff cue part instead of merging colored guide notes into the piano.
  Regression tests cover overlapping guide/piano material. A live native
  export/re-import of the private score preserves 1,439 pitched piano events,
  355 pitched guide events, and 193 measures per part; the structural audit has
  zero issues. The exporter adds only 15 explicit non-sounding rests to empty
  guide measures.
- [x] Preserve the imported measure map and every mid-score meter change through
  the core model, portable `.score` v14 persistence, live hot-reload ABI,
  MusicXML export, bar/beat display, measure looping, and metronome accents.
  The private export/re-import now remains exactly 193 measures, retains all 17
  emitted time-signature entries (including each 2/4 to 4/4 return), preserves
  all 1,794 pitched events / 2,575 note-rest events, and passes the structural
  audit with zero issues.
- [x] Make authored tempo changes first-class Flecs score data. Import every
  MusicXML metronome/`sound tempo` and Standard MIDI conductor event; advance
  the hot-reloadable transport across event boundaries; scale rubato around the
  editable practice-BPM baseline; persist it in `.score` v14; and round-trip
  the map through MusicXML and MIDI. This enables a verified recording-derived
  map but does not itself certify one.
- [x] Add an inclusive `--measures` phrase selector to the recording audit so
  one score section can be rebased to a lawful local audio excerpt instead of
  stretching a short excerpt across the entire work. Unit-test rebasing of
  measure and note times, and use it for the opening A/B review above.
- [x] Separate the printed metronome pulse from canonical quarter-note engine
  time without changing hot-reload ABI sizes. MusicXML eighth=147 now imports,
  displays, edits, persists, and re-exports as eighth=147 plus
  `sound tempo=73.5`; transport, practice timing, recorded MIDI takes, and SMF
  conductor events use 73.5 quarter notes/minute. Rewrite the ignored private
  MXL tempo metadata only, prove its 386 part/measures and 2,575 note/rest
  events are otherwise byte-semantically unchanged, and retain a local backup.
- [x] Playback, tempo, loop, count-in, metronome, and software piano synth.
- [x] Honor connected MusicXML tie chains in the playback timeline: suppress
  intermediate note-off/on re-attacks across exported measure segments while
  retaining safe attacks/releases for dangling OMR tie marks.
- [x] Derive non-loop playback bounds from the live Flecs score, stop exactly
  at the final event, emit final-frame notes before all-notes-off, and restart
  from beat zero/count-in when Play is pressed at the end. Cover this with a
  regression test and native visual verification.
- [x] Add `score-workbench audio-evidence`, a Zig 0.16 offline WAV analyzer with local
  downmix/resampling, leading/trailing silence detection, ranked global tempo
  plus a rolling 16-second tempo trace, bass/chroma/polyphonic pitch candidates,
  JSON output, and MusicXML/MXL alignment that ignores vocal-guide notes.
  Validate the end-to-end CLI on generated PCM audio; label its output as
  evidence rather than an authoritative transcription.
- [x] Add a reusable macOS Chrome/app -> BlackHole -> PCM24 WAV -> Zig analysis
  workflow. Discover the current AVFoundation loopback index, refuse accidental
  overwrite, reject prematurely-ended as well as silent captures, accept any
  optional MXL/MusicXML comparison, and restore the user's original output
  device from success, failure, or signal paths. Allow the capture input and
  macOS output route to be selected separately for preconfigured aggregate or
  multi-output devices; a real Aggregate Device probe is retained as rejected
  evidence because its selected channels measured only -91 dBFS silence.
- [x] Add deterministic chroma-overlap alignment for split reference captures,
  including active-audio offsets, best/runner-up similarity evidence, and a
  deliberately non-certifying review status. Cover the timing map and frame-rate
  validation with standalone regression tests.
- [x] Compose browser-controlled split takes into one anchored private evidence
  timeline, preserving per-frame capture provenance, explicit gaps, declared
  source ranges, and an exclusion list for interrupted/contaminated recordings.
- [x] Add an ignored authoring-only six-stem Demucs/Basic Pitch review path for
  the seven initially audible-but-empty accompaniment bars. Derive every
  transcription window from the lyric-constrained measure audit, then compile
  guitar/other/piano detections into per-measure normalized note and pitch-class
  candidates with raw-event/timing provenance and explicit `REVIEW_REQUIRED`
  status; never mutate the score or let a noisy stem dominate. A musician still
  has to resolve timing, hand assignment, voicing, dynamics, articulation, and
  pedal by ear.
- [x] Add a separate review-only score-native donor workflow for the two-hand
  reduction. It rescales MusicXML divisions safely, records each target/donor
  transplant in MXL metadata, and cannot mix candidate notes into the singer
  guide. A strict promotion gate requires structural PASS, lower anchored
  recording cost, fewer HIGH bars, unchanged lyric-anchor containment, notes
  in both hands, >=75% pitch-class agreement, and >=45% bass agreement when
  bass evidence exists. Measures 39<-110 and 63<-1 first passed, improving the
  anchored cost from 0.330879 to 0.328968 and HIGH bars from 69 to 67. A second
  combined gate now accepts 38<-47, 62<-114, 64<-115, and 97<-147: cost falls
  again to 0.327081, HIGH bars to 64, and all four targets become MANUAL with
  78.65%-100% pitch-class and 50%-100% bass agreement. Measure 65 candidates
  initially remained separate because the full mix's vocal overtones obscured
  its bass. A vocal-free accompaniment mix then gates the recording-derived
  A-flat/A-natural bass inflection at 100% pitch-class and bass agreement,
  lowering accompaniment cost 0.315818 -> 0.314392 and HIGH bars 63 -> 62.
  The full-mix report remains separately retained and non-certifying.
  Measures 150 and 152 then pass both references simultaneously after keeping
  their quarter-note rhythm and correcting only the recording-led bass motion:
  A-A-A-Ab and Gb-Gb-Gb-G. Full-mix cost falls to 0.321189 / 61 HIGH;
  vocal-free cost falls to 0.310129 / 60 HIGH. Both targets are MANUAL with
  86.38%-93.71% pitch and 50%-72.73% bass agreement.
  Measure 60 then passes both references after preserving its two half-note
  rhythm and retuning only B-flat/G-flat to D-flat/F. Full-mix cost reaches
  0.321093 / 60 HIGH with 99.46% pitch and 75% bass agreement; vocal-free cost
  reaches 0.309862 / 59 HIGH with 99.39% pitch and 50% bass agreement. The
  native GPU app reloads the resulting 174-measure / 2,348-event MXL at 147
  QPM, renders the five-flat spelling cleanly, plays through the bar, and
  export/reimports it without event loss or sampler drops/overloads.
  Measure 133 is the next dual-reference pass: its two authored half notes and
  every rest/voice/staff element are preserved while G-flat is retuned to
  A-flat. Full-mix cost drops to 0.318847 / 59 HIGH with 95.73% pitch and 100%
  bass agreement; vocal-free drops to 0.306919 / 58 HIGH with 95.8% pitch and
  100% bass agreement. A native Metal capture at bar 133 is clean and live
  playback again reports zero sampler drops/overloads.
- [x] Detect that the 12 supplied pages stop after the first final refrain while
  the accepted 5:35.827 recording contains a second occurrence. Re-OCR pages
  11-12 in sparse-layout mode, bound each repeated page occurrence to its own
  ASR window, and require independent score-text/page-OCR agreement at source
  measures 156/164/169 and appended measures 175/183/188. Append an exact
  two-part copy of measures 156-174 as 175-193, moving the terminal barline to
  the real ending. The dedicated extension gate passes: 23 anchors, unchanged
  0.52-second maximum deviation, complete recording-end coverage, no empty
  audible appended bar, and costs 0.296776 full mix / 0.279735 vocal-free.
  The native app imports and export/reimports 193 measures / 2,564 events,
  renders pages 44-49, plays through beat 756, and reports zero sampler faults.
  Repeat transition, notes, dynamics, articulation, pedal, and variable tempo
  remain `REVIEW_REQUIRED` until musician confirmation.
- [x] Correct five lower-staff bars in the two final-refrain occurrences from
  the accepted whole mix, the vocal-free accompaniment mix, and time-local
  guitar-stem events while preserving every existing quarter-note duration,
  rest, voice, and staff assignment. Measures 159/178 replace the OCR-derived
  G-flat/D-flat motion with B-flat2/F3 motion; the second occurrence alone uses
  an E-flat3 approach on its final quarter. Measures 161/180 use A-flat
  octaves, and later measure 185 independently uses A-flat octaves while its
  copied source measure 166 is deliberately rejected because its bass gate
  remains zero. The combined strict gates pass all five accepted targets:
  full-mix cost 0.296776 -> 0.284912 and HIGH 70 -> 64; vocal-free cost
  0.279735 -> 0.268818 and HIGH 68 -> 63. Target pitch agreement is
  86.52%-100%, bass agreement is 50%-100%, and every target becomes MANUAL.
  The native GPU pages 40/45 render cleanly and native export/reimport retains
  193 measures / 2,564 events, eighth=147 (73.5 QPM), and zero sampler faults.
- [x] Reject the next ambiguous measure-132 bass edit instead of promoting a
  detector guess. Four rhythm-preserving G/A-flat half-note variants all
  improve the global queues, but only the A-flat-octave variant passes the
  vocal-free target gate; every variant fails the independent whole-mix target
  pitch threshold. Retain the authored G-flat octaves and keep measure 132
  `REVIEW_REQUIRED` until a musician/ear pass resolves the disagreement.
- [x] Replace the unsupported A-flat-only fragment in piano measure 94 with a
  narrow recording-led two-hand candidate. The accepted full mix, vocal-free
  accompaniment, and six-stem Basic Pitch review agree on the D-flat/E-flat/
  F/B-flat upper material; aligned bass frames support the playable B-flat-F-
  A-flat-B-flat lower motion, while the supplied page-7 rhythm is used only as
  secondary engraving evidence. Both strict gates pass without threshold
  changes: full mix 0.284912 -> 0.281513 and HIGH 64 -> 63, with target
  96.57% pitch / 66.67% bass; vocal-free 0.268818 -> 0.266360 and HIGH 63 ->
  62, with target 91.45% pitch / 71.43% bass. The promoted private MXL remains
  structurally clean, native import/export/reimport retains 193 measures /
  2,575 events at eighth=147 (73.5 QPM), playback reports zero sampler drops/overloads, and a
  live system plus WGSL reload preserves the page and renders cleanly. Keep the
  bar `REVIEW_REQUIRED` pending musician fingering, articulation, dynamics,
  pedal, and final ear confirmation.
- [x] Correct the unsupported D-flat3/D-flat4 bass in piano measure 55 without
  changing its rhythm. The aligned full mix, vocal-free accompaniment, and
  six-stem review support A-flat2/A-flat3 in the target window. The promoted
  candidate changes only those two pitches and provenance metadata. Full-mix
  cost improves 0.281513 -> 0.281508 and HIGH 63 -> 62, with target 91.25%
  pitch / 50% bass; vocal-free cost remains exactly 0.266360 while HIGH falls
  62 -> 61, with target 100% pitch / 50% bass. The Pareto gate permits this
  cost-neutral global result because its separately enforced bass metric is
  register-aware, but still rejects any global regression. Native Metal bar-55
  playback advances correctly at eighth=147 (73.5 QPM); the sampled grand reports 1,704
  regions / 641 preloaded samples and zero drops/overloads; live Flecs/WGSL
  reload and GPU readback are clean. Export/re-import preserves 193 measures,
  2,575 note/rest events, and 1,794 pitched events with zero structural issues.
  Keep the bar `REVIEW_REQUIRED` pending musician voicing, fingering,
  dynamics, articulation, pedal, and final ear confirmation.
- [x] Correct piano measure 61's unsupported A-flat3/E-flat3 lower half notes.
  Both aligned references start at 100% overall pitch-class agreement but 0%
  bass agreement, and time-resolved guitar/other/piano stem events repeatedly
  identify F3 throughout the bar. Reject F3-D-flat3 because its bass result is
  only 25%/37.5%, and reject F3-C3 because it increases the full-mix HIGH queue
  and misses the vocal-free bass threshold. The promoted sustained-F3 version
  changes only the two lower pitches and provenance while preserving both
  half-note durations. Global costs remain 0.281508 full mix / 0.266360
  vocal-free, HIGH falls 62 -> 61 and 61 -> 60, and target agreement reaches
  100% pitch plus 75%/87.5% bass. Native Metal playback at bar 61, GPU
  readback, live Flecs/WGSL reload, sampled-grand telemetry, and export/reimport
  all pass with zero sampler drops/overloads and exact 193-measure / 2,575
  note-rest / 1,794-pitched-event retention. Keep the bar `REVIEW_REQUIRED`
  pending musician voicing, fingering, dynamics, articulation, pedal, and final
  ear confirmation.
- [x] Correct piano measure 120's unsupported A-flat3/E-flat4 lower pattern
  without changing its four existing eighth-note attacks or rests. Both aligned
  references start at 100% overall pitch-class agreement but 0% bass
  agreement; all three separated instrument stems identify F3, and the piano
  stem repeats it across the target window. Reject all three tested F/D-flat
  orderings because each misses a target bass threshold or increases the
  full-mix HIGH queue. The promoted four-F3 candidate changes only the lower
  pitches plus provenance. Full-mix cost improves 0.281508 -> 0.281096 and
  HIGH 61 -> 60 with 100% pitch / 60% bass; vocal-free cost improves 0.266360
  -> 0.266033 and HIGH 60 -> 59 with 100% pitch / 75% bass. Native Metal
  playback at bar 120, GPU readback, live Flecs/WGSL reload, sampled-grand
  telemetry, and export/reimport all pass with zero sampler faults and exact
  193-measure / 2,575-note-rest / 1,794-pitched-event retention. Keep the bar
  `REVIEW_REQUIRED` pending musician voicing, fingering, dynamics,
  articulation, pedal, and final ear confirmation.
- [x] Correct piano measure 119's unsupported A-flat3/E-flat4 lower pattern
  while preserving its four eighth-note attacks, beaming, and two quarter
  rests. Time-resolved accepted full/accompaniment mappings and the separated
  guitar/piano/other stems converge on C3-D-flat3-F3-C3. Both unchanged gates
  pass: full-mix cost 0.281096 -> 0.281024 and HIGH 60 -> 59 with 100% pitch /
  60% bass; vocal-free cost 0.266033 -> 0.265124 and HIGH 59 -> 58 with 100%
  pitch / 66.67% bass. Parsed-tree comparison proves every non-target semantic
  node unchanged. Native Metal bar-119 playback, visual readback, phrase-aware
  finger targets, live Flecs/WGSL reload, sampled-grand telemetry, and native
  export/re-import pass with zero faults and exact 193-measure / 2,575
  note-rest / 1,794-pitched-event retention. Keep the bar `REVIEW_REQUIRED`
  pending musician voicing, fingering, dynamics, articulation, pedal, and final
  ear confirmation.
- [x] Correct measure 121's B-flat3/D-flat4/G-flat3/B-flat3 lower pattern to
  four F3 attacks while preserving its two paired eighth-note figures, beaming,
  and quarter rests. Every mapped bass frame in both accepted timelines is F3.
  Both unchanged gates pass with 100% pitch / 100% bass: full-mix cost
  0.281024 -> 0.280010 and HIGH 59 -> 58; vocal-free cost 0.265124 -> 0.263877
  and HIGH 58 -> 57. Non-target parsed semantics are identical. Native Metal
  playback/readback, phrase finger state, Flecs/WGSL reload, zero-fault sampled
  grand telemetry, and export/re-import all pass with exact 193-measure / 2,575
  note-rest / 1,794-pitched-event retention. Keep the bar `REVIEW_REQUIRED` for
  musician articulation, dynamics, voicing, pedal, and final ear confirmation.
- [x] Correct opening piano measure 5's unsupported A-flat2/A-flat3 lower
  attacks to G-flat2/G-flat3 without changing either eighth-note onset, any
  rest, duration, voice, staff, or non-target XML node. The accepted whole mix,
  vocal-free accompaniment, and separated guitar/piano/other stems converge on
  the G-flat register. Both unchanged gates pass: full-mix alignment improves
  0.280010 -> 0.279377 and HIGH 58 -> 57 with 83.27% pitch / 50% bass;
  vocal-free improves 0.263877 -> 0.263063 and HIGH 57 -> 56 with 90.47% pitch
  / 66.67% bass. Native Metal bar-5 playback and readback, live Flecs/WGSL
  reload, sampled-grand telemetry, and the exact 193-measure / 2,575-note-rest
  document all pass with zero sampler drops/overloads. Keep the bar
  `REVIEW_REQUIRED` pending a musician's voicing, fingering, articulation,
  dynamics, pedal, and ear confirmation.
- [x] Correct opening measure 9's G-flat2/G-flat3 lower attacks to
  A-flat2/A-flat3 after the fixed-window audit resolves the old adjacent-bar
  DTW ambiguity. Locked whole-mix cost improves 0.318745 -> 0.317536 and HIGH
  62 -> 61 with 88.86% pitch / 75% bass; locked vocal-free cost improves
  0.291094 -> 0.289975 and HIGH 59 -> 58 with 78% pitch / 75% bass. The bounded
  opening audit improves 0.249940 -> 0.241808 and HIGH 6 -> 5. Exact-tree
  comparison proves only the two pitch nodes plus one private evidence field
  changed. Keep the bar `REVIEW_REQUIRED` for final musician voicing,
  fingering, articulation, dynamics, pedal, and ear confirmation.
- [x] Correct opening measure 10 as one coherent two-hand, rhythm-preserving
  voice rather than judging its bass in isolation. Retune the five existing
  right-hand attacks to F4-D-flat4-D-flat4-F4-D-flat4 and the two existing
  left-hand attacks to A-flat2-B-flat2. Locked whole-mix cost improves
  0.317536 -> 0.314599 and HIGH 61 -> 60 with 95.24% pitch / 80% bass;
  locked accompaniment cost improves 0.289975 -> 0.286912 and HIGH 58 -> 57
  with 85.17% pitch / 50% bass. The bounded opening audit improves to
  0.217273 and HIGH 3. A canonical parsed-tree comparison proves that only the
  seven target pitches plus two private evidence fields changed; all rhythms,
  rests, beams, voices, staves, and 2,575 note/rest events are unchanged.
  Native M3 Max Metal capture at bar 10 is clean; playback advances 2.48
  quarters in two seconds at eighth=147, and the 1,704-region sampler reports
  zero drops/overloads. Native export/re-import remains structurally clean at
  193 measures with a 1,439-note two-staff piano part and separate 355-note /
  468-cue optional vocal guide. Keep measure 10 `REVIEW_REQUIRED` pending
  musician voicing, fingering, articulation, dynamics, pedal, and ear review.
- [x] Correct opening measure 11 with the same whole-voice discipline:
  F4-D-flat4-D-flat4-F4-F4 in the five preserved right-hand attacks and
  B-flat2/B-flat3 in the two preserved left-hand attacks. Locked whole-mix
  cost improves 0.314599 -> 0.312613 with unchanged HIGH 60, while the target
  improves MEDIUM -> MANUAL at 100% pitch / 75% bass. Locked accompaniment
  improves 0.286912 -> 0.285514 and HIGH 57 -> 56, with the target HIGH ->
  MANUAL at 87.66% pitch / 75% bass. The bounded opening cost improves
  0.217273 -> 0.208844 without increasing its three HIGH bars. Exact semantic
  diffing proves only six pitch nodes and two private provenance fields change;
  every authored onset, duration, rest, beam, voice, and staff remains intact.
  Native Metal bar-11 rendering/playback is clean at eighth=147 and sampled
  playback remains at zero drops/overloads. Keep the measure
  `REVIEW_REQUIRED` for musician voicing, fingering, articulation, dynamics,
  pedal, and final ear confirmation.
- [x] Correct opening measure 8 from convergent onset-level evidence while
  preserving its complete rhythm: only the first upper A-flat4 becomes F4 and
  the second lower B-flat3 becomes A-flat3, leaving the supported second
  A-flat4, three F4 attacks, and first B-flat2 intact. Guitar/piano/other stems
  independently support that mixed contour. Locked whole-mix improves
  0.312613 -> 0.311322 and HIGH 60 -> 59, with the target HIGH -> MANUAL at
  92.10% pitch / 60% bass. Locked accompaniment improves 0.285514 -> 0.284850
  with HIGH unchanged at 56 and the target MEDIUM -> MANUAL at 95.75% pitch /
  50% bass. The opening crop remains MANUAL at 100% pitch / 100% bass and its
  cost improves 0.208844 -> 0.206276. Exact-tree comparison proves only two
  pitch nodes plus private provenance change. Native Metal readback/playback at
  bar 8 is clean at eighth=147 with zero sampler drops/overloads. Keep the bar
  `REVIEW_REQUIRED` for musician voicing, fingering, dynamics, articulation,
  pedal, and ear confirmation.
- [x] Generalize the dual-reference promotion gate from “HIGH must always
  fall” to a true Pareto rule: alignment cost and HIGH count may not regress,
  and at least one must improve, while every target must still be two-hand,
  non-HIGH, and above the unchanged strict pitch/bass thresholds. Regression
  tests cover cost-only progress, queue-only progress, no-progress rejection,
  structural failure, bass failure, and cost regression. This allows a MEDIUM
  bar such as measure 11 to become MANUAL without fabricating a global HIGH
  reduction.
- [x] Reject isolated opening-bass substitutions at measures 2, 6, 8, 10, and
  11 when they fail either locked reference's unchanged local/global gates.
  Measure 10 only passes after the evidence-supported upper and lower voices
  are evaluated together; do not promote detector-led partial edits merely
  because one crop or one metric improves.
- [x] Leave opening measures 6, 7, and 12 unresolved after explicit
  time-resolved bass-frame analysis. Their locked whole-mix and accompaniment
  fundamentals disagree in ways that no two-attack, rhythm-preserving pitch
  pair can clear in both references; measure 12 is especially clear at 20%
  whole-mix versus 75% accompaniment bass agreement. Do not invent extra bass
  attacks or weaken the 45% local threshold to clear the queue. Require a
  musician ear/piano decision or stronger learned source separation/alignment.
- [x] Correct measure 50's unsupported B-flat2/B-flat3 lower attacks to
  A-flat2/A-flat3 without touching its authored upper voice or any rhythm.
  Both locked references and guitar/piano/other stem events sustain the A-flat
  register across the two attacks. A batch of five plausible upper rewrites
  all scores worse than retaining the source upper line, so only the two bass
  pitch nodes change. Locked whole-mix improves 0.311322 -> 0.310638 and HIGH
  59 -> 58 with 92.73% pitch / 100% bass; locked accompaniment improves
  0.284850 -> 0.283416 and HIGH 56 -> 55 with 91.49% pitch / 100% bass.
  Exact-tree comparison, structural audit, native Metal bar-50 readback,
  playback at eighth=147, and the 1,704-region sampler all pass with zero
  dropped/overloaded voices. Keep the bar `REVIEW_REQUIRED` for musician
  voicing, fingering, dynamics, articulation, pedal, and final ear review.
- [x] Correct measure 59 as a complete rhythm-preserving two-hand texture from
  the fixed whole-mix and accepted accompaniment windows plus the separated
  guitar/other events. The five existing upper attacks become
  G-flat4-D-flat4-D-flat4-A-flat4-A-flat4 and the two existing lower attacks
  become B-flat2/G-flat3; every onset, duration, rest, voice, staff, beam, and
  the 2,575-event document size remain unchanged. Three weaker variants were
  retained only as private diagnostics. The selected line passes both formal
  Pareto gates: locked whole-mix improves 0.310638 -> 0.308245 and HIGH 58 ->
  57, while locked accompaniment improves 0.283416 -> 0.280379 and HIGH 55 ->
  54. Both target reports move HIGH -> MANUAL with 100% pitch-class and 66.67%
  bass agreement. Canonical diffing confines the edit to exactly seven P2/m59
  pitch nodes plus two private provenance fields. Native Metal rendering,
  2-second playback, export/re-import, state-preserving systems/WGSL reload,
  the 1,704-region V6.2 sampler gate, and the ad-hoc-signed ReleaseSafe arm64
  bundle all pass with zero queue drops or overloads. Keep the bar
  `REVIEW_REQUIRED` pending musician voicing, fingering, dynamics,
  articulation, pedal, and final ear review.
- [x] Correct the compact 2/4 measure 66 without expanding its sparse authored
  rhythm. The first upper A-flat4 becomes F4, the supported second A-flat4
  stays, and the two lower attacks become A2/A-flat3. Time-resolved locked
  windows explain the chromatic bass: the whole mix reports A2-E-flat3-A-flat3
  while the accepted accompaniment reports A-flat throughout, so A2 followed
  by A-flat clears both unchanged gates. Locked whole-mix improves 0.308245 ->
  0.307313 and HIGH 57 -> 56 with 87.16% pitch / 66.67% bass; locked
  accompaniment improves 0.280379 -> 0.279697 and HIGH 54 -> 53 with 85.85%
  pitch / 66.67% bass. Exact diffing confines the edit to three P2/m66 pitch
  nodes plus private provenance. Native Metal capture/playback,
  export/re-import, systems/WGSL hot reload, the sampled-grand telemetry, and
  all 75 Python plus Zig tests pass with zero queue drops or overloads. Keep
  the measure `REVIEW_REQUIRED` for musician voicing, fingering, dynamics,
  articulation, pedal, and final ear review.
- [x] Correct measure 72's G-flat lower octave to B-flat2/B-flat3 and retune
  its five preserved upper attacks to B-flat4-B-flat4-D-flat4-F4-D-flat4.
  Both locked references and the separated guitar agree on the B-flat bass.
  Four structurally identical upper variants were gated; the selected contour
  deliberately retains the quarter-note F4 that Basic Pitch detects from
  121.681 to 122.180 seconds, instead of choosing the detector's slightly
  cheaper all-D-flat alternative. Locked whole-mix improves 0.307313 ->
  0.305325 and HIGH 56 -> 55 at 94.35% pitch / 100% bass; locked
  accompaniment improves 0.279697 -> 0.277542 and HIGH 53 -> 52 at 96.23%
  pitch / 100% bass. Exact diffing finds six P2/m72 pitch changes and no
  rhythmic or structural change. Native Metal capture/playback,
  export/re-import, systems/WGSL reload, and the 1,704-region sampler telemetry
  pass with zero faults. Keep the bar `REVIEW_REQUIRED` for musician voicing,
  fingering, dynamics, articulation, pedal, and final ear review.
- [x] Leave measure 76 unresolved instead of replacing its authored D-flat
  lower attacks with a detector compromise. The fixed whole-mix bass frames
  move G-flat -> C while the accepted accompaniment frames move C -> D-flat;
  meanwhile the higher-resolution guitar Basic Pitch events repeatedly detect
  D-flat3 from 126.002 through 126.873 seconds, supporting the authored pitch
  class. The only shared-threshold compromise, C3/C3, lowers the whole-mix HIGH
  queue cost-neutrally but worsens accompaniment cost 0.277542 -> 0.277805, so
  the unchanged dual Pareto gate rejects it even before musical adjudication.
  Keep the original bar `HIGH` / `REVIEW_REQUIRED`; require a musician ear pass
  or improved beat alignment rather than optimizing through conflicting
  fundamentals.
- [x] Correct measure 96's sustained lower whole note from D-flat3 to G-flat2
  while preserving the complete A-flat3/D-flat4 upper dyad, all four-quarter
  durations, voices, staves, and the 2,575-event private document. Both locked
  recording references sustain G-flat in the target window. Locked whole-mix
  cost improves 0.305325 -> 0.304103 and HIGH 55 -> 54 with 93.17% pitch /
  66.67% bass agreement; locked accompaniment improves 0.277542 -> 0.276789
  and HIGH 52 -> 51 with 97.41% pitch / 75% bass agreement. Exact-tree
  comparison confines the score edit to one P2/m96 pitch node plus private
  provenance. Native Metal capture/playback at bar 96, page 24/49, fingering,
  eighth=147 transport, systems/WGSL reload, and the 1,704-region sampled grand
  all pass with zero queue drops or overloads. MusicXML export/re-import keeps
  all 1,439 pitched piano and 355 pitched vocal events; its 15-event count
  increase consists only of explicit full-measure rests canonically filling
  empty vocal-guide measures. Keep measure 96 `REVIEW_REQUIRED` for musician
  voicing, fingering, dynamics, articulation, pedal, and final ear review.
- [x] Leave measure 102 unresolved after separating a plausible register fix
  from a detector-led chromatic rewrite. Moving its repeated B-flat3/F4 lower
  figure down to B-flat2/F3 matches the secondary page, key, and separated
  guitar, but it reaches only 72.54% pitch / 25% bass in the locked whole mix
  and remains HIGH at 61.28% pitch / 14.29% bass in accompaniment. The only
  tested variant that clears both numeric gates inserts A-natural2 before
  A-flat2/E-flat3, contradicting the B-flat-minor figure, the five-flat key,
  and the Basic Pitch B-flat events. Do not promote that metric artifact.
  Keep m102 `HIGH` / `REVIEW_REQUIRED` pending stronger alignment or a musician
  ear-and-piano decision.
- [x] Correct measure 103 as a complete D-flat-over-A-flat arpeggio while
  preserving all authored quarter rests, eighth-note attacks, beams, voices,
  staves, and the 2,575-event document. Its repeated upper B-flat4 becomes F4
  while both D-flat5 attacks remain; the lower B-flat3/F4 pairs become
  A-flat2/A-flat3. Locked frames and separated guitar independently sustain
  A-flat, D-flat, and F across the bar. The selected full chord is preferred
  over passing but third-less and detector-led alternatives. Locked whole-mix
  cost improves 0.304103 -> 0.302313 and HIGH 54 -> 53 with 84.15% pitch /
  85.71% bass agreement; locked accompaniment improves 0.276789 -> 0.274686
  and HIGH 51 -> 50 with 79.52% pitch / 100% bass agreement. Exact event
  comparison finds six P2/m103 pitch changes and no non-pitch change. Native
  Metal page-26 capture, fingering, playback at eighth=147, MXL export/reimport,
  systems/WGSL reload, the 1,704-region sampler, all 75 Python tests, and Zig
  tests pass with zero queue drops or overloads. Keep m103 `REVIEW_REQUIRED`
  for musician voicing, fingering, dynamics, articulation, pedal, and ear
  confirmation.
- [x] Correct measure 106 as a complete, playable G-flat-major-seventh spread
  using only its existing simultaneous attack, eighth-note arpeggio, rests,
  beams, voices, and staves. Each lower half becomes G-flat2+B-flat3 followed
  by D-flat4; each upper half becomes D-flat4-F4. The full G-flat/B-flat/
  D-flat/F pitch set is independently present in locked frames and separated
  guitar events. Twelve complete distributions were gated; this one preserves
  the chord's third and seventh and clears both references, unlike register-
  only, third-less, and reordered variants. Locked whole-mix cost improves
  0.302313 -> 0.301416 and HIGH 53 -> 52 at 80.09% pitch / 66.67% bass;
  locked accompaniment improves 0.274686 -> 0.273175 and HIGH 50 -> 49 at
  92.98% pitch / 100% bass. Exact comparison finds ten P2/m106 pitch changes,
  no non-pitch changes, and the same 2,575 events. Native Metal page-27
  capture, fingering, eighth=147 playback, MXL export/reimport, systems/WGSL
  reload, the 1,704-region sampler, Python tests, and Zig tests pass with zero
  queue drops or overloads. Keep m106 `REVIEW_REQUIRED` for musician voicing,
  fingering, dynamics, articulation, pedal, and final ear confirmation.
- [x] Correct measure 110 as a D-flat/add-nine color over A-flat without adding
  or deleting any authored event. Each lower simultaneous attack becomes
  A-flat2+E-flat3 followed by D-flat4; each upper pair becomes A-flat3-F4.
  Locked frames and separated guitar repeatedly contain A-flat, E-flat,
  D-flat, and F. Ten complete distributions were evaluated; this is the only
  musically coherent candidate that clears both unchanged gates. Locked
  whole-mix cost improves 0.301416 -> 0.299985 and HIGH 52 -> 51 at 79.72%
  pitch / 100% bass; locked accompaniment improves 0.273175 -> 0.272603 and
  HIGH 49 -> 48 at 79.41% pitch / 50% bass. Exact comparison finds ten
  P2/m110 pitch changes and no non-pitch or 2,575-event-count change. Native
  Metal page-28 capture, fingering, eighth=147 playback, MXL export/reimport,
  systems/WGSL reload, sampled-grand telemetry, all 75 Python tests, and Zig
  tests pass without queue drops or overloads. Keep m110 `REVIEW_REQUIRED` for
  musician voicing, fingering, dynamics, articulation, pedal, and final ear
  confirmation.
- [x] Leave measure 111 unresolved after testing the repeated m110 voicing and
  seven additional complete diatonic D-flat/add-nine and F-minor-seven
  distributions. The locked bass frames alternate A-flat, A-natural, E-flat,
  and D-natural; no musically coherent same-rhythm candidate clears both local
  pitch/bass gates. The strongest full-mix F-minor candidate reaches only
  68.28% pitch / 50% bass, while accompaniment reaches 66.68% pitch / 25%
  bass. Do not insert detector-led A-natural/D-natural notes merely to reduce
  global cost. Keep m111 `HIGH` / `REVIEW_REQUIRED` for better alignment or a
  musician ear-and-piano decision.
- [x] Correct measure 114 as a time-resolved two-harmony transition while
  preserving every authored rest, eighth-note onset, duration, beam, voice,
  staff, and the 2,575-event document. The lower line is B-flat2-D-flat4 in
  the first half and C3-B-flat3 in the second; the upper pairs are
  B-flat4-D-flat5 and A-flat4-D-flat5. Nine complete controls were evaluated
  against the independently locked full and vocal-free windows. The selected
  shell follows the common B-flat/D-flat opening, accompaniment C transition,
  and late B-flat/A-flat/D-flat evidence instead of repeating one chord across
  the bar. Locked whole-mix cost improves 0.299985 -> 0.299385 and HIGH
  51 -> 50 at 79.89% pitch / 66.67% bass agreement; locked accompaniment
  improves 0.272603 -> 0.272299 and HIGH 48 -> 47 at 78.47% pitch / 60%
  bass agreement. Exact formatted-XML and event-ledger comparison confines the
  promotion to four P2/m114 pitch nodes plus two private provenance fields;
  an earlier generic rewrite that added redundant stem nodes was rejected and
  rebuilt with the rhythm-preserving retuner. Native Metal page-29 rendering,
  fingering, eighth=147 sampled playback, source-name-aware MXL export/reimport,
  systems/WGSL hot reload, the 1,704-region sampler, all 75 Python tests, and
  Zig tests pass without queue drops or overloads. Keep m114
  `REVIEW_REQUIRED` for musician voicing, fingering, dynamics, articulation,
  pedal, and final ear confirmation.
- [x] Correct measure 115 as a time-resolved D-flat-to-A-flat broken-chord
  figure without changing its authored rhythm or structure. The first lower
  pair becomes D-flat3-D-flat4, the second becomes A-flat2-A-flat3, and both
  upper pairs become A-flat4-D-flat5. Six static and register-control voicings
  all exposed the same issue: the locked full mix begins on D-flat before its
  sustained A-flat bass, so repeating either root across the whole bar cannot
  clear both references. The selected split voicing improves locked whole-mix
  cost 0.299385 -> 0.296574 and HIGH 50 -> 49 at 87.02% pitch / 71.43% bass;
  locked accompaniment improves 0.272299 -> 0.269897 and HIGH 47 -> 46 at
  94.18% pitch / 100% bass. Exact formatted-XML comparison confines the edit
  to six P2/m115 pitch nodes plus two private provenance fields. Native Metal
  page-29 rendering, fingering, eighth=147 playback, semantic MusicXML/MXL
  export/reimport, systems/WGSL hot reload, and the 1,704-region sampler pass
  with zero drops or overloads. Keep m115 `REVIEW_REQUIRED` for musician
  voicing, fingering, dynamics, articulation, pedal, and ear confirmation.
- [x] Correct measure 124 as a layered F3+B-flat3 sustained left-hand dyad
  while preserving the authored upper E-flat5-A-flat5-F5 figure, rests, beams,
  voices, staves, and two half-note onsets. The isolated piano sustains F3 as
  the guitar sustains B-flat3; seven single-bass and alternate-upper controls
  each discarded one of those simultaneous layers and missed the vocal-free
  bass gate by one mapped frame. The complete dyad improves locked whole-mix
  cost 0.296574 -> 0.296037 and HIGH 49 -> 48 at 81.54% pitch / 100% bass;
  locked accompaniment improves 0.269897 -> 0.268431 and HIGH 46 -> 45 at
  97.58% pitch / 85.71% bass. The exact XML diff retunes the two authored bass
  notes, adds one chord tone at each existing half-note onset, and adds one
  private provenance field; the document therefore grows intentionally from
  2,575 to 2,577 events. Native Metal page-31 chord engraving, left-hand
  F3(5)-B-flat3(2) fingering, eighth=147 playback, semantic MXL
  export/reimport, systems/WGSL hot reload, and sampler telemetry pass without
  drops or overloads. Keep m124 `REVIEW_REQUIRED` for musician voicing,
  dynamics, articulation, pedal, and final ear confirmation.
- [x] Correct measure 131 as two sustained D-flat/F/A-flat left-hand shells
  while preserving the authored upper E-flat5-A-flat5-F5 eighth-note figure.
  A-flat-only and A-flat/D-flat controls either fail local evidence or miss the
  whole-mix threshold; the complete shell is the coherent dual-reference pass.
  Locked whole-mix cost improves 0.296037 -> 0.293537 and HIGH 48 -> 47 at
  100% pitch / 100% bass; locked accompaniment improves 0.268431 -> 0.265771
  and HIGH 45 -> 44 at 97.55% pitch / 50% bass. The exact XML diff retunes two
  B-flat3 notes to A-flat3 and adds D-flat4/F4 at the same two half-note
  onsets, increasing the private score from 2,577 to 2,581 events. Native GPU
  page-33 engraving, left-hand 4-2-1 fingering, eighth=147 playback timing,
  semantic MXL export/reimport, systems/WGSL reload, and all automated tests
  pass with the 1,704-region sampler reporting zero drops/overloads. Keep m131
  `REVIEW_REQUIRED` for musician voicing, dynamics, articulation, pedal, and
  final ear confirmation.
- [x] Leave measure 136 unresolved after seven rhythm-preserving lower-line
  controls. Its existing upper figure already reaches 94.08% accompaniment
  pitch agreement, but the authored D-flat3/D-flat4 bass has zero agreement.
  The best full-mix B-flat3/A-flat2 control lowers HIGH 47 -> 46 at 70.29%
  pitch / 50% bass but strongly regresses accompaniment; the strongest
  accompaniment A-flat2/D-flat4 control retains 94.08% pitch / 100% bass but
  fails the full mix. No candidate passes both locked references, so do not
  trade one source for the other or modify the private score. Keep m136 `HIGH`
  / `REVIEW_REQUIRED` for better alignment or musician adjudication.
- [x] Correct the 2/4 measure 138 with one sustained F3-A-flat3-D-flat4
  left-hand shell while preserving its complete E-flat5-A-flat5-F5 upper
  figure, meter, rest, beam, voice, staff, and duration. Eight single-note,
  octave, dyad, and shell controls were gated with the same 23 independent
  anchors. The selected D-flat/F/A-flat voicing strictly dominates the other
  dual passes: locked whole-mix cost improves 0.293537 -> 0.292779 and HIGH
  47 -> 46 at 100% pitch / 50% bass; accompaniment improves 0.265771 ->
  0.264673 and HIGH 44 -> 43 at 100% pitch / 100% bass. Exact XML comparison
  confines the edit to B-flat3 -> F3, two added chord tones at the same onset,
  and one private provenance field; the score grows from 2,581 to 2,583 events.
  Native page-35 rendering, meter clearance, F3(5)-A-flat3(4)-D-flat4(2)
  fingering, eighth=147 timing, sampler telemetry, semantic MXL export/reimport,
  and systems/WGSL hot reload pass with zero faults. Keep m138
  `REVIEW_REQUIRED` for musician voicing, dynamics, articulation, pedal, and
  final ear confirmation.
- [x] Make locked candidate audits reject an omitted anchor argument when the
  timing baseline contains anchor diagnostics. This prevents a candidate from
  producing a misleading gate failure with empty diagnostics; regression
  coverage requires the same explicit anchor evidence used by the baseline.
- [x] Leave measure 139 unresolved after seven stem-coherent A-flat/D-flat/F
  shells and five mixture-led G/G-flat bass-motion controls. The coherent
  shells reach 100% pitch agreement and improve both global costs/HIGH queues,
  but miss the strict bass gates at 28.57% full / 33.33% accompaniment. The
  only full-mix-passing diagnostic motion, G3 -> A-flat3, fails accompaniment
  at 0% bass; no candidate passes both references. Do not turn conflicting
  low-frequency detectors into authored chromatic notes. Keep m139 unchanged,
  `HIGH`, and `REVIEW_REQUIRED` pending better separation/alignment or musician
  adjudication.
- [x] Leave measure 140 unresolved after six A-flat/D-flat/F register,
  completeness, and time-resolved controls. Every coherent candidate passes
  accompaniment at up to 100% pitch / 100% bass, but whole-mix bass agreement
  remains 20% because that window is dominated by an A-natural2 absent from
  the vocal-free reference and separated guitar/piano. Do not add a sustained
  chromatic A-natural merely to satisfy contaminated full-mix bass frames.
  Keep m140 unchanged, `HIGH`, and `REVIEW_REQUIRED` pending a cleaner full-mix
  window or musician adjudication.
- [x] Correct measure 150 with four playable B-flat2-F3-B-flat3 left-hand
  quarter-note shells while preserving its complete upper voice and rhythm.
  Eight single-line controls fail at least one locked reference; four compact
  shell controls pass both. Choose the directly supported octave-and-fifth
  voicing rather than the numerically marginally cheaper B-flat/F/D-flat tenth,
  which is less playable and less directly supported by the separated guitar.
  Locked whole-mix cost improves 0.292779 -> 0.290657 and HIGH 46 -> 45 at
  93.61% pitch / 50% bass; accompaniment improves 0.264673 -> 0.263269 and
  HIGH 43 -> 42 at 99.13% pitch / 71.43% bass. Exact comparison confines the
  semantic edit to m150 and grows the score from 2,583 to 2,591 events. Native
  page-38 rendering, 5-3-1 fingering, eighth=147 playback, semantic MXL
  export/reimport, WGSL reload, and the 1,704-region sampler pass with zero
  faults. Keep m150 `REVIEW_REQUIRED` for musician voicing, dynamics,
  articulation, pedal, and final ear confirmation.
- [x] Correct transitional measure 151 with two B-flat2-F3 quarter-note dyads
  followed by two A-flat2-E-flat3 dyads. Seven static, shell, and time-resolved
  controls show that this is the sole dual-reference pass and it matches the
  separated bass/guitar handoff instead of forcing either overlapping locked
  window's static answer. Whole-mix cost improves 0.290657 -> 0.289700 and HIGH
  45 -> 44 at 91.49% pitch / 50% bass; accompaniment improves 0.263269 ->
  0.261618 and HIGH 42 -> 41 at 90.89% pitch / 64.29% bass. The exact semantic
  diff is limited to m151, the private score grows from 2,591 to 2,595 events,
  and strong dual-reference coverage reaches 61 measures. Native page-38
  engraving, fingering, eighth=147 playback, MXL export/reimport, WGSL reload,
  and sampled-grand telemetry pass with zero faults. Keep m151
  `REVIEW_REQUIRED` for musician voicing, dynamics, articulation, pedal, and
  final ear confirmation.
- [x] Leave measure 152 unresolved after testing the directly supported
  A-flat2-A-flat2-A-flat2-A2 motion plus octave and fifth-shell controls. The
  vocal-free gate passes at 96.24% pitch / 66.67% bass and the whole-mix
  candidate improves cost 0.289700 -> 0.287427 and HIGH 44 -> 43, but its
  whole-mix bass score is 41.67%, one 250 ms frame below the unchanged 45%
  threshold. Do not weaken the gate or add an unsupported G solely to collect
  that frame; retain m152 unchanged and `HIGH` pending better alignment or
  musician adjudication.
- [x] Correct measure 153 by retuning the preserved four-quarter alternating
  B-flat2/B-flat3 octave to A2/A3. Static-A and repeated-octave controls are
  pitch-class equivalent; choose the alternating line because it preserves the
  authored texture and event count. Locked whole-mix cost improves 0.289700 ->
  0.287885 and HIGH 44 -> 43 at 81.93% pitch / 57.14% bass; accompaniment
  improves 0.261618 -> 0.260527 and HIGH 41 -> 40 at 90.17% pitch / 58.33%
  bass. Exact comparison changes only four m153 pitch nodes. Native page-39
  rendering, 5-to-1 octave fingering, eighth=147 playback, semantic MXL
  export/reimport, WGSL reload, and sampled-grand telemetry pass with zero
  faults; strong dual-reference coverage reaches 62 measures. Keep m153
  `REVIEW_REQUIRED` for musician dynamics, articulation, pedal, and final ear
  confirmation.
- [x] Leave measure 155 unresolved after six E-flat/G-flat transition, octave,
  and shell controls. Every playable candidate worsens the locked whole-mix
  and accompaniment global costs; the sole accompaniment pass is an
  unplayable 18-semitone E-flat2-G-flat3-A3 diagnostic shell. Do not promote a
  local HIGH reduction that globally regresses the fixed alignment or cannot
  be played by one hand. Keep m155 unchanged, `HIGH`, and `REVIEW_REQUIRED`.
- [x] Leave measure 160 unresolved after five time-resolved F/E-flat/A and
  common-class controls. All pass accompaniment except the F-to-E-flat
  half-bar line, but none passes whole mix. The best whole-mix F3-F3-A2-A3
  line lowers cost and HIGH but misses bass by one mapped frame at 42.86%; do
  not add unsupported E-natural/D solely to satisfy detector residue. Keep
  m160 unchanged, `HIGH`, and `REVIEW_REQUIRED`.
- [x] Correct measure 163 by retuning its preserved alternating A-flat2/A-flat3
  octaves to G-flat2/G-flat3. Both locked references independently rank the
  G-flat octave first, so no extra notes or rhythm rewrite is needed.
  Whole-mix cost improves 0.287885 -> 0.286583 and HIGH 43 -> 42 at 79.07%
  pitch / 83.33% bass; accompaniment improves 0.260527 -> 0.259538 and HIGH
  40 -> 39 at 77.66% pitch / 71.43% bass. Exact comparison changes only four
  m163 pitch nodes and preserves the 2,595-event count. Native page-41
  engraving, 5-to-1 octave fingering, eighth=147 playback, semantic MXL
  export/reimport, WGSL reload, and sampled-grand telemetry pass with zero
  faults; strong dual-reference coverage reaches 63 measures. Keep m163
  `REVIEW_REQUIRED` for musician dynamics, articulation, pedal, and ear review.
- [x] Leave measure 165 unresolved after D-flat/C/D/C, D-flat/C, static-C, and
  D-flat/C/F/E-flat controls. None passes both local gates; the most faithful
  time-resolved line also slightly worsens accompaniment cost. Keep m165
  unchanged, `HIGH`, and `REVIEW_REQUIRED` rather than turning a detector
  sequence into unsupported notation.
- [x] Correct measure 166 with a single D3 pickup followed by three E-flat3
  quarter notes. A static E-flat line misses whole mix by one frame, an
  alternating D/E-flat line passes but overuses the chromatic pickup, and the
  separated stems support D only at the transition onset. The tightened line
  passes both locked gates: whole-mix cost 0.286583 -> 0.285635 and HIGH 42 ->
  41 at 86.81% pitch / 50% bass; accompaniment cost 0.259538 -> 0.258985 and
  HIGH 39 -> 38 at 88.80% pitch / 50% bass. Exact comparison changes only four
  m166 pitch nodes and preserves the 2,595-event count. Native page-42
  engraving, guided fingering, eighth=147 playback, semantic MXL
  export/reimport, WGSL reload, and sampler telemetry pass with zero faults;
  strong dual-reference coverage reaches 64 measures. Keep m166
  `REVIEW_REQUIRED` for musician dynamics, articulation, pedal, and ear review.
- [x] Correct measure 177's copied G-flat3/D-flat4 lower line to one D-flat3
  quarter followed by three B-flat3 quarters. Six first-pass register and
  alternating-line controls either regress a locked cost or miss the bass gate;
  the accepted time-resolved line follows the separated guitar/other/piano
  transition and clears both unchanged references. Whole-mix cost improves
  0.285635 -> 0.284812 and HIGH 41 -> 40 at 85.57% pitch / 57.14% bass;
  accompaniment improves 0.258985 -> 0.258550 and HIGH 38 -> 37 at 83.18%
  pitch / 50% bass. Exact comparison changes only four m177 pitch nodes and
  preserves the 2,595-event count. Native page-45 engraving, 5-to-1 guided
  fingering, eighth=147 playback, normalized semantic MXL export/reimport,
  WGSL/system reload, and the 1,704-region sampled grand pass with zero faults;
  strong dual-reference coverage reaches 65 measures. Keep m177
  `REVIEW_REQUIRED` for musician dynamics, articulation, pedal, and ear review.
- [x] Correct measure 179's copied B-flat octave to F3-A-flat3-A-flat2-A-flat3
  while preserving its four quarter-note attacks. The shared full/accompaniment
  window and separated guitar stem show the F-to-A-flat transition and sustained
  A-flat octave; D-flat-led and static-octave controls also pass, but this line
  has the best combined local agreement and lower accompaniment cost. Whole-mix
  improves 0.284812 -> 0.283430 and HIGH 40 -> 39 at 100% pitch / 62.5% bass;
  accompaniment improves 0.258550 -> 0.255678 and HIGH 37 -> 36 at 97.03%
  pitch / 87.5% bass. Exact comparison changes only four m179 pitch nodes and
  preserves 2,595 events. Native page-45 engraving, guided fingering,
  eighth=147 playback, normalized semantic MXL export/reimport, and the sampled
  grand pass with zero faults; strong dual-reference coverage reaches 66
  measures. Keep m179 `REVIEW_REQUIRED` for musician dynamics, articulation,
  pedal, and ear review.
- [x] Replace measure 183's unsupported G-flat3/D-flat4 alternation with a
  playable four-beat shell line: B-flat2, B-flat2+A-flat3,
  B-flat2+F3, D-flat3+F3. Single-note controls cannot reconcile the shifted
  full/accompaniment frame windows; these seventh, fifth, and minor-third
  shells cover the independently supported chord tones without a chromatic
  cluster or an unplayable span. Whole-mix improves 0.283430 -> 0.281225 and
  HIGH 39 -> 38 at 96.46% pitch / 78.57% bass; accompaniment improves
  0.255678 -> 0.254951 and HIGH 36 -> 35 at 87.18% pitch / 71.43% bass. Exact
  comparison is confined to m183, adds three intentional chord tones, and
  brings the private source to 2,598 events. Native page-46 engraving,
  four-to-two guided fingering, eighth=147 playback, normalized semantic MXL
  export/reimport, and the sampled grand pass with zero faults; strong
  dual-reference coverage reaches 67 measures. Keep m183 `REVIEW_REQUIRED`
  for musician dynamics, articulation, pedal, and ear review.
- [x] Correct measure 184's copied G-flat3/D-flat4 lower line to
  D-flat3-E-flat3-E-flat3-E-flat3 with the four quarter attacks unchanged. The
  exact full/accompaniment frame intersection agrees on the chromatic pickup
  and repeated E-flat, so no added harmony or threshold exception is needed.
  Whole-mix improves 0.281225 -> 0.280087 and HIGH 38 -> 37 at 98.13% pitch /
  62.5% bass; accompaniment improves 0.254951 -> 0.252827 and HIGH 35 -> 34 at
  96.14% pitch / 56.25% bass. Exact comparison changes only four m184 pitch
  nodes and preserves 2,598 events. Native page-46 engraving, three-to-two
  guided fingering, a historical playback check now superseded by the current
  quarter=147 gate, normalized semantic MXL
  export/reimport, and the sampled grand pass with zero faults; strong
  dual-reference coverage reaches 68 measures. Keep m184 `REVIEW_REQUIRED`
  for musician dynamics, articulation, pedal, and ear review.
- [x] Stop the recording audit from treating sub-threshold silence as proof of
  wrong notes. Reuse the existing 0.003 RMS audibility boundary: a score with
  authored accompaniment over quieter evidence is now `MANUAL` with an
  explicit sustain/release ear-review reason, while a missing left hand still
  remains `HIGH`. Regression coverage proves the distinction. Only full-mix
  m191-m193 and accompaniment m192 change classification; costs, mappings,
  pitches, and the private score remain untouched. Accompaniment m191/m193
  stay `HIGH`, and every tail bar stays `REVIEW_REQUIRED`. This removes three
  false shared-HIGH intersections without claiming the ending is certified;
  the shared queue is now 13 measures.
- [x] Ensure the consolidated Zig score transformation path does not invent
  stem elements when evidence does not explicitly request them. Stems may
  still be authored at the replacement or individual-event level. Regression
  coverage for omitted and explicit stems prevents the redundant-node issue
  caught during the m114 exact-tree gate from recurring in chord candidates.
- [x] Record the exact evidence artifact path in every newly generated
  score/recording audit. Regression-test the field so similarly named full,
  accompaniment, and phase-projected analyses cannot be silently mixed during
  candidate promotion. Upper-staff retunes now also carry explicit
  `recording-voice-review-candidate` provenance instead of being mislabeled as
  bass candidates.
- [x] Add fixed-measure-window candidate auditing after proving that a two-note
  edit could make unconstrained whole-song DTW jump to a different repeated
  phrase. `--timing-from` now distributes score frames deterministically inside
  an accepted baseline review's measure windows; regression tests prove pitch
  edits cannot retime unrelated measures. Keep free-DTW reports as independent
  diagnostics, but use locked base/candidate pairs for note-promotion deltas.
- [x] Correct opening piano measure 3's B-flat2/B-flat3 lower attacks to
  A-flat2/A-flat3 while preserving every onset, duration, rest, voice, staff,
  and non-target semantic XML node. The bounded opening audit improves
  0.272430 -> 0.249940 and HIGH 7 -> 6. On fixed whole-mix windows the cost
  improves 0.319907 -> 0.318745 and HIGH 63 -> 62 with 82.71% pitch / 100%
  bass; fixed vocal-free windows improve 0.292284 -> 0.291094 and HIGH 60 ->
  59 with 94.71% pitch / 100% bass. Exact-tree comparison proves only the two
  pitch nodes and one private evidence field change. Native Metal rendering and
  playback at bar 3 pass at eighth=147 with zero sampler drops/overloads.
  Keep the bar `REVIEW_REQUIRED` for final musician voicing, fingering,
  articulation, dynamics, pedal, and ear confirmation.
- [x] Reject opening measure 2's F2/F3 bass hypothesis. On locked whole-mix
  windows it raises cost 0.319907 -> 0.320093 and HIGH 63 -> 64; vocal-free
  bass agreement remains 0% and the target remains HIGH. The bounded opening
  HIGH count also does not improve. Keep the authored D-flat attacks pending
  stronger time-local evidence or a musician decision.
- [x] Reject measure 118's unresolved lower-voice rewrite. The musically
  coherent stem-led B-flat2-B-flat2-G-flat2-A-flat2 pattern preserves all four
  attacks/rests and improves global cost 0.281024 -> 0.280847 full mix and
  0.265124 -> 0.263546 vocal-free. It passes accompaniment at 100% pitch / 80%
  bass but reaches only 94.75% pitch / 40% bass in the whole mix, below the
  unchanged 45% bass gate. A detector-favored A-natural would chase the metric
  without separated-stem support and is not promoted. Keep the authored bar
  `HIGH` / `REVIEW_REQUIRED` for an ear-and-piano decision.
- [x] Expose bass-detector ambiguity without weakening the correction gates.
  Each measure report now includes a non-gating
  `low_register_candidate_agreement` derived from the frame's primary bass plus
  ranked sub-C4 pitch candidates. Exact, alternative, miss, and absent-evidence
  behavior is unit-tested. The strict `bass_pitch_class_agreement` remains the
  promotion threshold; the additional metric explains possible harmonic or
  semitone errors instead of silently treating them as fundamentals.
- [x] Adjudicate measure 43 as detector-ambiguous and leave it unchanged. Its
  authored A-flat2/A-flat3 is repeatedly present in guitar, piano, and other
  stem events. The primary detector reports A-natural and yields 0%/25% bass,
  while the new low-register candidate metric recovers 50%/75% A-flat support
  from those same full/accompaniment frames. Do not replace independently
  supported A-flat with a one-semitone detector artifact; keep the bar
  `REVIEW_REQUIRED` for a musician ear pass.
- [x] Reject the ambiguous measure-114 lower-voice edit. Five
  rhythm-preserving B-flat/F/D-flat/A-flat variants all lower one or both HIGH
  counts, but none passes both independent references: sustained B-flat2 and
  B-flat/B-flat/F/F worsen the vocal-free global cost, while the
  B-flat/B-flat/D-flat/A-flat stem contour worsens the full-mix cost. Retain the
  existing bar as `HIGH` / `REVIEW_REQUIRED` until an ear-and-piano pass can
  resolve the disagreement; never trade one reference regression for a lower
  queue count.
- [x] Reject measure 171's tempting detector-led bass rewrite. Both accepted
  timelines report 100% overall pitch-class but 0% bass agreement for the
  authored A-flat3/F3 halves. Seven register/rhythm variants test the
  time-resolved B-flat, G-flat, A-flat, and F evidence from the whole mix,
  vocal-free mix, and guitar/piano/other stems. The strongest sparse line
  (B-flat2 quarter, G-flat2 half, A-flat2 quarter) reaches 100% pitch and
  50%/87.5% bass, lowering both HIGH queues by one, but worsens global cost
  0.281096 -> 0.281143 and 0.266033 -> 0.266088. Both unchanged Pareto gates
  therefore reject it. Keep the authored bar `HIGH` / `REVIEW_REQUIRED` until
  an ear-and-piano pass can distinguish musical bass from separated-stem
  fundamentals and alignment/onset ambiguity.
- [x] Add a phase-consistent STFT projection for private Demucs stem groups. It
  distributes the complex residual by local time-frequency energy, reconstructs
  an all-stem selection against the mixture in regression tests, streams the
  full 332.7-second reference without clipping, and records provenance. The
  vocal-free candidate improves global cost 0.263877 -> 0.256938 but worsens
  HIGH measures 57 -> 70 and anchor escapes 2 -> 3, so the non-regression gate
  correctly rejects it; no score notes are changed.
- [ ] Add stronger learned multi-pitch transcription, section/beat alignment,
  confidence heatmaps, and an in-app manual correction workflow for user-owned
  reference audio. Never download/rip protected streaming audio; accept lawful
  local exports and keep them ignored/private.
- [ ] Finish a measure-by-measure, recording-led arrangement audit for the
  private Holocene study score. The playable piano part must be a musically
  coherent two-hand reduction of the recording's piano/harp accompaniment—not
  a direct copy of one scanned staff—and must carry note, rhythm, voicing,
  dynamics, articulation, and pedal evidence. Keep the vocal melody and lyrics
  on their independent optional singer-guide staff. Leave every unaudited bar
  marked `REVIEW_REQUIRED`; structural MusicXML validity is not musical proof.
- [x] Generate the first instrument-only, measure-level recording comparison
  queue with constrained time warping, right/left-hand note counts, pitch-class
  agreement, bass agreement, timing ranges, and explicit priorities. Keep the
  output non-certifying so it drives—not replaces—the professional review.
  The earlier unconstrained queue established the D-flat correction but was
  later found susceptible to repeated-section jumps and a silence-favoring
  local cost. The corrected lyric-constrained baseline is 0.330879 with 69 HIGH
  measures; the first six strictly gated additions improve it to 0.327081 and
  64 HIGH measures. The final empty bar, measure 65, is resolved against a
  Demucs-derived vocal-free accompaniment reference: that audit reaches
  0.314392 / 62 HIGH, with 100% target pitch-class and bass agreement. The
  whole-mix audit is intentionally retained too (0.327166 / 63 HIGH, target
  MEDIUM), because separation and alignment are review aids rather than proof.
  The dual-gated measure-150/152 bass correction further lowers the whole-mix
  queue to 0.321189 / 61 HIGH and the vocal-free queue to 0.310129 / 60 HIGH.
  The dual-gated measure-60 half-note correction lowers those again to
  0.321093 / 60 HIGH and 0.309862 / 59 HIGH respectively.
  The dual-gated measure-133 pitch-only correction lowers the current queues to
  0.318847 / 59 HIGH and 0.306919 / 58 HIGH.
  The full-recording repeat extension adds 19 reviewable bars, so absolute HIGH
  counts become 70/193 full mix and 68/193 vocal-free while normalized costs
  improve to 0.296776 and 0.279735. Its separate gate compares full-timeline
  coverage, copied hand-note counts, anchor containment, and review density;
  it does not misrepresent the larger queue as a like-for-like count reduction.
  Five subsequent final-refrain bass corrections pass both references and
  lower the current queues to 0.284912 / 64 HIGH full mix and 0.268818 / 63
  HIGH vocal-free. The source/repeat pair is edited together only when both
  occurrences agree; measure 185 is accepted alone because the recording's
  later cadence differs and the same edit fails at source measure 166.
  The later measure-94 full-voice replacement passes both references and lowers
  the current queues again to 0.281513 / 63 HIGH full mix and 0.266360 / 62
  HIGH vocal-free.
  The subsequent measure-55 bass correction lowers the current queues to
  0.281508 / 62 HIGH full mix and 0.266360 / 61 HIGH vocal-free. Its
  vocal-free global cost is neutral while its register-aware bass result and
  HIGH count improve, so the Pareto gate accepts it without weakening any
  target threshold.
  The measure-61 sustained-F3 correction keeps those global costs neutral and
  lowers the current queues again to 0.281508 / 61 HIGH full mix and 0.266360 /
  60 HIGH vocal-free, with 100% target pitch-class and 75%/87.5% bass
  agreement.
  The measure-120 four-F3 correction lowers the current queues to 0.281096 / 60
  HIGH full mix and 0.266033 / 59 HIGH vocal-free, with 100% target pitch-class
  and 60%/75% bass agreement.
  No audible aligned bar is now entirely empty, but every unaudited musical
  decision still requires a musician ear/piano pass.
- [ ] Build the production audio path as a general multi-sampled instrument
  engine, not a piano-only special case: reusable key/velocity zones,
  round-robin groups, articulations, envelopes, filters, LFO/modulation matrix,
  streaming, buses, effects, automation, and per-instrument metadata. Make the
  concert grand the first reference-quality library, then support electric
  pianos, organs, strings, percussion, and licensed/user sample packs without
  changing the score or transport core.
- [x] Vendor the current official sfizz engine as a pinned submodule and build
  its Apple-silicon shared library reproducibly. Route native score/MIDI events
  through an allocation-free SPSC queue so sfizz MIDI and rendering remain on
  the CoreAudio callback thread.
- [x] Correct the sfizz C-API event boundary: its first integer is a sample
  delay, not a MIDI channel. Native events now enter at delay zero instead of
  shifting source channels 1...15 by 1...15 samples; channel identity remains
  intact in score, practice, recording, and exported MIDI data. Centralize the
  Salamander CC20...23 studio profile, report audio-thread-applied values from
  `sampler state`, and hot-adjust `studio`, `dry`, or four explicit values with
  `sampler detail` without restarting the Flecs world.
- [x] Download the full CC-BY Salamander Grand Piano V3 into ignored local
  content as the fallback pack and load its 1,121 SFZ regions / 641 preloaded
  samples. Native piano playback crossed from oscillator voices to its 48
  kHz/24-bit, 16-velocity-layer Yamaha C5 recordings and release/string/pedal
  regions. Preserve the license and attribution with any optional asset pack.
- [x] Add a deterministic offline sampler proof renderer and PCM16 WAV encoder.
  Verify a 12-second stereo render containing velocity changes, overlapping
  notes, sustain down/up, releases, and chords: no clipping, peak -10.3 dBFS,
  RMS -31.6 dBFS, and approximately 86 dB measured dynamic range.
- [x] Land the allocation-free normalized instrument-zone foundation: sample
  metadata, attack/release/pedal triggers, key/velocity/pedal/soft ranges,
  equal-power velocity crossfades, deterministic round robins, mic buses,
  preload/stream policy, validation, and selection tests. The diagnostic synth
  is not yet connected to decoded sample voices.
- [ ] Add an optional GPU instrument editor inspired by Bitwig's clear device
  workflow: searchable/tagged library browser; resizable key/velocity/select
  zone map; per-zone root/range/crossfade/round-robin/layer controls; waveform,
  loop, zero-crossing, envelope, filter, and modulation views; live voice and
  streaming meters. Keep this editor out of the focused practice layout.
- [ ] Import well-defined SFZ, SF2, and open multisample libraries into a
  normalized internal manifest; support lossless FLAC/WAV assets, validation,
  content hashes, missing-sample diagnostics, and round-trip-safe user packs.
- [ ] Provide reusable note-input, note-release, and post-instrument FX chains
  so release articulations and effects remain composable; support explicit
  RAM-preload or disk-stream modes per library/zone and surface their memory,
  I/O, polyphony, and underrun costs.
- [ ] Replace the diagnostic oscillator piano with a professionally recorded,
  properly licensed, state-of-the-art concert-grand engine: lossless multi-mic
  samples, dense velocity layers with continuous timbre/level interpolation,
  sensible round robins, release/key-off and mechanical samples, pedal-up/down
  samples, per-note sympathetic/string/damper resonance, una-corda timbre, and
  click-free priority-aware voice stealing.
  Native playback has crossed the real-sample boundary with Salamander/sfizz;
  this remains open until the same engine is active in Wasm/iOS and the
  multi-mic, continuous half-pedal, sympathetic-resonance, spatial, and blind
  listening gates below clear.
- [ ] Add production piano spatialization: selectable close/player/room mic
  perspectives, phase-aligned mic mixing, high-quality convolution rooms,
  binaural/headphone output, lid/listener-position controls, and loudness-safe
  master limiting without hiding dynamics.
- [ ] Support high-resolution MIDI 2.0/per-note expression where available,
  preserve MIDI 1.0 compatibility, and make velocity/touch and pedal response
  curves calibratable per keyboard.
- [ ] Implement a cross-platform streaming sampler in the Zig core with the same
  musical behavior on native, Wasm/WebAudio worklet, and iOS; keep decoding,
  audio device, and asset I/O behind platform facades and never block the audio
  callback or allocate from it.
- [ ] Finish production pedal behavior: pedal noise, repedaling, continuous
  sampler half-pedal/resonance, per-note sustain state, and calibrated hardware
  response curves. Raw recorded-take controller capture/persistence/export is
  complete; this remaining item is about how the production sampler sounds and
  responds to those values.
- [x] Correct the shared Zig synth's pedal state machine: key-up voices under
  sustain/sostenuto now decay without re-entering attack, CC64 values 0...63
  continuously scale release time, repedaling catches a still-audible released
  voice without an envelope jump, and releasing sostenuto defers to an active
  sustain pedal. This closes the portable diagnostic path; sfizz resonance,
  noises, calibration, and the browser/iOS production engine remain open.
- [x] Import Standard MIDI CC64 sustain, CC66 sostenuto, and CC67 una corda as
  ordered semantic score automation while preserving continuous 0...127 values
  and PPQ timing. Isolate active-note state per Type-1 track, reject malformed
  high-bit data bytes, extend document/playback bounds through the final pedal
  event, and emit the imported controller events during sampler playback. Prove
  live native import with a beat-5 sustain release and two rendered pedal events.
- [x] Export deterministic Type-1 Standard MIDI at 480 PPQ with a conductor
  track, piano track, optional vocal-guide track, title/tempo/meter/key metadata,
  connected-tie sustain, velocities, channels, and ordered CC64/66/67 values.
  Route the native save panel and Debug export command by `.musicxml`, `.mid`/
  `.midi`, or `.score` extension. Prove live `.mid` export/re-import preserves
  the beat-5 pedal tail and is recognized as format 1 by the operating system.
- [x] Export an unquantized recorded performance as deterministic Type-1
  Standard MIDI using the take's captured tempo and monotonic nanosecond
  timestamps. Preserve channel voice messages and continuous controller values,
  expose GPU `REPLAY` / `EXPORT MIDI` actions plus semantic accessibility,
  native save panel, and Debug `export-take`/`record`/`midi` commands. Persist
  take tempo and raw events in portable `.score` v11. Prove a live four-event
  note/pedal take survives save/reload and exports byte-identically afterward.
- [x] Route MIDI CC64/66/67 through the native and browser real-time queues;
  implement sustain release, sostenuto latching, una-corda diagnostic timbre,
  recording capture, and live three-pedal position indicators. Production
  half-pedal/resonance/noise behavior remains part of the sampler milestone.
- [x] Make score pedal notation and the guided-piano pedal overlay toggleable
  from the GPU transport UI, `G` shortcut, semantic accessibility controls, and
  the Debug hot-control channel without discarding the imported document.
- [x] Place each pedal-expression lane below measured bass-note ink instead of
  at a fixed staff offset, leaving clearance for low notes, downward stems,
  beams, articulations, and dynamics in the live Metal engraving.
- [x] Import timed MusicXML sustain-pedal start/stop/change/continue/resume/
  discontinue directions, preserve their line/sign intent in portable `.score`
  v11, export/re-import them, render analytic score pedal marks/lines, schedule
  CC64 into native sampler playback, and compare threshold-crossing live pedal
  input with the score. The guided-piano header distinguishes live fill from
  the expected score marker and turns a mismatch rose; late transitions enter
  practice feedback. Verify 44 directions from the bundled CC0 Für Elise
  through live import, Metal capture, playback, export, and re-import.
- [ ] Finish the three-pedal score guide: authored sostenuto/soft events,
  continuous half-press curves, longer-horizon change/release previews before their
  onset, missed-event accounting even when no controller input arrives, and
  per-measure pedal heatmaps. MusicXML's standard `<pedal>` direction currently
  supplies sustain only; do not imply that CC66/67 score automation exists.
- [x] Add the native offline sampler acceptance executable: idle-silence and
  finite-PCM checks, eight-point velocity response, a seven-point continuous
  CC64 curve, sampled-release/hammer/pedal-noise/resonance A/B probes,
  repedaling, stable MIDI attack replay, nonzero-source-channel input, and
  no-drop/no-unclamped-overload stress. Render comparisons from fresh sampler
  instances so live release tails cannot contaminate the next probe. Emit
  schema-2 JSON plus a PCM16 evidence WAV and fail the build step when a gate
  fails. Three consecutive V6.2 runs pass all acoustic-layer and repedaling
  gates; its permitted replay variation remains stable at 0.919...1.0
  correlation. V3 remains stable at 0.939 correlation. Do not require
  bit-exact output from a sample engine with legitimate random/round-robin
  variation. An exact-digital-silence tail is correctly treated as infinite
  positive decay instead of a failed negative ratio.
- [ ] Extend sampler quality/performance verification with latency calibration,
  spectral/reference regression, audible velocity-transition review, and blind
  listening on studio monitors/headphones across Mac, browser, and iPad.
- [ ] Treat sample provenance, redistribution license, download size, integrity
  hashes, optional asset packs, and offline installation as release-blocking;
  never ship an unclear or non-redistributable piano library.
- [x] Evaluate Accurate-Salamander Grand V6.2beta2 as a CC-BY development pack.
  The ignored official 1,657,769,640-byte archive has SHA-256
  `4abf8f81751176534ead0130fdb078931941d887ebf6690c0b7203033d811dbd`;
  its recommended live SFZ loads 1,704 regions / 641 samples and is now the
  native default when installed (V3 remains the fallback). The native gate
  measures 33.478 dB across the eight-point velocity sweep, the documented dry/
  partial/full CC64 curve, independently audible sampled release, hammer,
  pedal-mechanism, and resonance layers, 6.235 dB more caught-note energy after
  repedaling, stable MIDI attack replay, and zero queue drops/raw-mix overloads.
  Record Chisato Yamauchi/Alexander Holm attribution and CC BY 3.0 under
  `legal/third-party-notices/`. Browser streaming/memory cost, multi-mic sound,
  and blind listening remain open; this is not yet the final reference grand.
- [x] MIDI input/output and microphone pitch observation.
- [x] Practice assessment for pitch and timing.
- [x] Audio + MIDI take recording and replay.
- [x] Use a unique per-process temporary autosave before atomic replacement so
  simultaneous development instances cannot trample the same staging file.
- [x] Isolate the hot-reload host journal as `autosave-dev.score` so older open
  native/release windows cannot overwrite development recovery. Cold-restart
  QA recovered the private score at exactly 193 measures, 2,575 events, and
  an explicit eighth-note pulse of 147 BPM without re-importing it.
- [x] Read/edit/ink/practice tools, selection, insertion, movement, deletion,
  annotations, undo, and redo.
- [ ] Extend MusicXML export to preserve every remaining engraving detail plus
  freehand/semantic annotation data beyond the completed standard note-level
  fingering round trip.
- [ ] Robust polyphonic microphone transcription and calibrated latency model.
- [ ] Practice history, difficult-measure heatmap, and actionable phrase-level
  coaching.

## Cross-platform verification

- [x] macOS Dawn/Metal application bundle builds and launches.
- [x] Exercise the live native Debug control surface end-to-end: transport,
  seek/tempo, tool mode, keyboard/voice visibility, loop/metronome, MusicXML
  export/re-import, state restoration, and real GPU framebuffer capture.
- [x] Web build uses WebGPU only and reports unsupported browsers clearly.
- [x] iOS Metal bridge consumes the shared draw packet.
- [x] Re-run Zig unit/regression suite after the hand removal and exporter work.
- [x] Rebuild and smoke-test macOS bundle.
- [x] Rebuild and visually browser-test Wasm/WebGPU plus bundled MusicXML import,
  accessibility, GPU rendering, and exporter wiring with no runtime warnings.
- [ ] Browser-test microphone/MIDI permissions, physical-device input, audio
  take recording, IndexedDB recovery, and downloaded MusicXML in MuseScore.
- [x] Rebuild the iOS arm64 core and ad-hoc signed simulator application.
- [ ] Launch on device/simulator and verify touch, Metal, audio, MIDI,
  microphone, file import/export, orientation, and accessibility.
- [ ] Performance profile large scores and maintain smooth interaction at 120 Hz
  on supported iPad hardware.
