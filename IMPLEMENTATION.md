# Cross-Platform GPU Music Application — Implementation

> Current correction (2026-08-24): the private study score and native
> transport use **quarter-note = 147**. All historical statements below that
> report eighth=147 / 73.5 quarter-QPM playback are superseded and require a
> fresh musical QA pass. Repository score tooling is now consolidated in the
> Zig `score-workbench`; the former Python pipeline is retired. The user has
> accepted the current private score as the frozen practice baseline, so older
> `REVIEW_REQUIRED` narrative is provenance rather than an active transcription
> gate unless that decision is explicitly reopened.

Status: native macOS release candidate verified; WebGPU/Wasm and iPadOS/Metal
builds use the shared Zig/Flecs UI and sampled-piano core and pass browser/iPad
simulator smoke tests. Physical MIDI/microphone, VoiceOver, listening, and
120-Hz iPad hardware acceptance remain device-lab work.

Updated: 2026-08-25

Working name: **Score** (replace before public release)

Core language/runtime: **Zig 0.16.0 + Flecs 4.1.6**

Primary validation target: **native macOS through Dawn/Metal**

Browser distribution target: **WebAssembly + WebGPU only**, behind the same platform facades

## 0. Implemented baseline

This document started as the architecture plan and now also records the working implementation. The following is present and build-verified:

- A Zig-owned Flecs world with persistent score/session components, replaceable system descriptors, deterministic transport progression, native frame-boundary dylib reload while the world remains alive, and a Debug-only local Zig control client for repeatable live-state QA.
- Native hot reload is resource-safe: screen-composition and Flecs systems swap
  in place, while atlas/ABI/renderer changes rebuild and relaunch the host. A
  glyph-atlas content hash in ABI v11 prevents new UV metadata from sampling an
  old Metal texture. This contract prevents the corrupted text/music atlas seen
  when only one side of the hot-module boundary changed. Debug builds can
  capture the real Dawn/Metal framebuffer for repeatable visual QA.
- Debug iOS builds provide the equivalent last-good Metal path. The host seeds
  a writable `ScoreShaders.metal` in application support, compiles changed
  source and a complete candidate pipeline asynchronously, and swaps it only
  on the main render thread after both entry points validate. Invalid source
  retains the current pipeline and live Zig/Flecs world with exact Metal
  diagnostics; `zig build dev-ios` launches the simulator and mirrors edits.
- A signed macOS `.app` using Dawn/Metal, CoreAudio/AudioUnit, CoreMIDI, AudioQueue microphone capture, native import/export panels, app-support autosave, and WAV take replay.
- A separate shared-Zig/Flecs performance-controller workspace rendered by the
  same GPU packet pipeline: responsive 4×4 multitouch note/clip/action pads,
  eight transport squares, octave/bank/protocol controls, a persistent custom
  User bank, and an explicit GPU editor for message kind/value/channel,
  momentary/toggle behavior, and color. Editing selects mappings without
  emitting controller output; the compact versioned mapping blob remains
  separate from score documents. The workspace has semantic
  accessibility, Debug live-control commands, and a bounded core output queue.
  The core encodes complete OSC 1.0 datagrams or MIDI 1.0 channel messages;
  platform facades only deliver them. macOS and iPadOS publish a `Score
  Controller` virtual CoreMIDI source; iPadOS additionally enables Network
  MIDI. Direct UDP OSC implements current DrivenByMoss note, poly-aftertouch,
  clip-launch, action, and transport paths. Apple Pencil force drives the
  velocity response and per-note aftertouch, while non-pressure finger input
  truthfully uses a configured fixed velocity.
- Multi-controller identity is a platform-facade concern, not shared UI state.
  Each Apple CoreMIDI source has a device-qualified endpoint name and native
  name collisions receive deterministic suffixes. The development Bitwig
  bridge owns one UDP socket, keys sources by sender IP/port, and reserves one
  Bitwig `NoteInput` plus per-channel held-note table for each of 16 concurrent
  sources. Capacity exhaustion rejects the new source; it never wraps onto an
  existing controller. This was verified live with native Score and iPad
  Simulator sending the same C3 through two stable source ports, including an
  overlapping hold/release pass, followed by a 17-source saturation pass.
  Bitwig requires a declared MIDI port to own recordable `NoteInput` objects,
  so Debug `score-devctl bitwig-bootstrap` supplies a headless, message-free
  CoreMIDI endpoint. It is independent of Score app lifecycles: iPad input
  continued before, during, and after a native Score instance joined slot 2.
- A shared path-free version-4 `.scorebank` (with version-2 and version-3 read compatibility)
  and allocation-free 128-layer-voice Zig piano
  callback used by the browser AudioWorklet and iOS AVAudioSourceNode. The
  bundled licensed Salamander derivative contains 353 deduplicated PCM16
  samples and 931 regions in 135.3 MiB: 704 attack regions (all 88 keys ×
  eight recorded velocity layers), 68 sampled damper releases for the damped
  keys, 88 per-key hammer releases, 69 authored pedal-resonance regions, and
  recorded pedal-down/up mechanisms. It implements pitch/sample-rate
  conversion, equal-power interpolation between adjacent recorded velocity
  layers, priority-aware de-clicked voice stealing, stereo key position,
  sustain/half-pedal release, repedaling, sostenuto, una corda, room
  response, DC rejection, and linked limiting; a deterministic offline gate
  checks finite output, clipping, attack, dynamics, sustain, and safety.
  The callback is also exposed as the general `Instrument` API and performs
  validated sustain loops for held/sustain/sostenuto attack voices, including
  fractional loop-boundary interpolation and release into the authored sample
  tail. Explicit SFZ `ampeg_attack`, `ampeg_decay`, `ampeg_sustain`, and
  `ampeg_release` values survive normalization and packing and run as
  sample-accurate attack/decay/sustain/release stages; legacy regions retain
  their prior envelope behavior. One-shot release/mechanism layers remain
  non-looping. Version 4 also carries validated per-zone SFZ filter mode,
  cutoff, resonance, key tracking, key center, and velocity tracking. The
  allocation-free callback implements one-pole low/high pass, RBJ two-pole
  low/high/band-pass/band-reject, and cascaded four-pole low/high-pass modes;
  versions 2 and 3 decode with filters disabled. This supplies the
  core playback primitive required by organs, strings, pads, and looped
  electric instruments without changing the non-looped grand; general pack
  compilation and per-zone synthesis controls remain open.
- Debug/native recovery uses a separate atomic `autosave-dev.score` journal:
  it survives a hot-reload host relaunch without racing older release windows.
  Debug-control imports synchronously replace that atomic journal before the
  command succeeds, so a subsequent host rebuild cannot restore the score that
  preceded the import. Release and Debug also persist separate absolute source
  paths and content fingerprints; an explicit launch document is authoritative
  and a changed tracked MusicXML/MXL source replaces an obsolete journal.
  Native source-load and hot-reload QA recover the current private score at
  exactly 195 measures, 2,781 events, 75 harmonies, 15 pedal events, and an explicit quarter-note
  pulse of 147 BPM.
- The current ignored private MXL contains a two-staff piano reduction plus a
  separate optional vocal guide: 195 measures, 2,781 note/rest events, 2,041
  pitched events, 1,686 instrumental events, 485 vocal-guide events, 75
  harmonies, 15 pedal events, and 54 performed velocity levels from 41 through
  94. Exact structural repeats and narrowly gated enrichments improve both
  anchored stem and independent accompaniment-frame evidence. Evidence-generated
  notes retain key-aware enharmonic spelling, so black-key pitches in this
  five-flat score engrave as flats rather than arbitrary sharps.
  A Zig playability audit also checks instrument range, duration validity,
  simultaneous chord size, attack interval, per-hand span, and duplicate
  same-voice pitch/onset nodes. Its only two
  over-octave attacks were the repeated G-flat2/B-flat3 left-hand tenth in
  measure 106; pitch-preserving hand redistribution reduces the maximum hand
  span to one octave with no out-of-range notes, invalid durations, or
  over-five-note hand clusters.
  It is technically playable. A later explicit request reopened the formerly
  frozen opening and the private file remains a recording-led practice
  reduction, not an authoritative published concert transcription; older
  `REVIEW_REQUIRED` entries below remain provenance for the bounded edits that
  led to the current revision.
- Opening fidelity is now gated by both retained-audio comparison and a native
  sampler audition. The retained upper broken-note figure is the piano
  reduction of the recording's harp/guitar shimmer; it is not a missing part.
  Twenty-two restrained lower-staff attacks now add the missing instrumental
  body in measures 1..3 and its measures 8..10 return without replacing that
  upper line. Over the exact 80-quarter-beat / 32.653-second opening, aligned
  three-stem evidence improves exact matches from 146/192 to 165/214 and
  pitch-class matches from 169/192 to 191/214. Against the separated,
  phase-consistent accompaniment, envelope/attack/sustain correlation improves
  from 0.393275/0.488125/0.304848 to
  0.412251/0.504432/0.335728, normalized error falls from 0.281437 to 0.275876,
  and onset precision rises from 0.700000 to 0.736842. The anchor-locked audit
  cost falls from 0.375696 to 0.374520 with four fewer HIGH-priority measures.
  The 214-note sampled render retains all 15 pedal events, has no overloads or
  invalid output, and passes the mechanical playability audit at quarter=147.
  It remains `REVIEW_REQUIRED`; automated evidence does not replace a musician
  ear and piano pass.
- The user's final opening audition narrowed the accepted correction further:
  nine isolated lower-staff attacks in measures 1..3 were the source of the
  confusing entrance and have been removed. The upper harp/guitar shimmer is
  unchanged, the coherent lower register still enters in measure 4, and all
  later notation remains byte-semantically unchanged. The current ignored MXL
  contains 195 measures, 2,772 note/rest events, 2,032 pitched events, 1,677
  instrumental events, 485 separate vocal-guide events, 75 harmonies, 15 pedal
  events, and quarter=147. It passes the consolidated Zig playability gate and
  an Accurate Salamander opening render with zero overloads. The exact document
  has been hot-loaded in native Dawn/Metal, installed into the iPad simulator's
  recovery journal, and imported into WebGPU through the normal MusicXML path;
  browser reload restores it from IndexedDB. The earlier denser opening remains
  an ignored recovery file, not an active autosave or application default.
- iPad journal restoration now completes before the first-frame autosave
  callback is armed. This closes the startup race that could replace a valid
  imported score with the tutorial. Browser development accepts an optional
  same-origin `?score=relative.mxl` URL, imports through the same Zig semantic
  importer used by the picker, persists to IndexedDB, and removes the query
  parameter after success. Neither mechanism changes release content or adds a
  second notation implementation.
- Physical-device Library imports no longer allocate full 4,096-note reports,
  render scratch, or the 8,192-event playback timeline on the iOS UI-thread
  stack. Those buffers now live in caller-owned or heap-resident Zig-core
  storage. An attached iPad loaded Bach, Für Elise, the built-in tutorial, and
  the ignored private Holocene MXL sequentially with status 0 and no crash.
  Holocene is a normal private-study Library choice rather than application
  branding. `zig build install-ios-device` is the one-command Zig-driven
  physical build/provision/sign/install/launch workflow.
- Native and iPad audio acceptance is now measured at the platform callback,
  not inferred from a moving transport. A one-host-at-a-time macOS pass loaded
  the 195-measure / 2,772-event / 15-pedal canonical score, found and cleared a
  muted `MacBook Pro Speakers` CoreAudio route, and produced 1,712,314 nonzero
  samples at peak 0.108410 with no sampler faults. The matching iPad recovery
  journal drove AVAudioEngine through 55 events, including four CC64 sustain
  changes at value 72, and produced 603,086 nonzero samples at peak 0.255432.
  The iPad counters and autoplay are enabled only by the explicit
  `SCORE_IOS_ACCEPTANCE=1` test environment and are dormant in normal builds.
- Browser audio startup is a readiness handshake rather than a fire-and-forget
  side effect. The host prepares the portable 135.3 MiB grand bank in a
  suspended AudioContext, resumes that existing context directly from a Play
  gesture, and reports sampler-ready only after the worklet has committed all
  931 regions / 353 samples and the context is actually running. Core transport
  remains stationary while that handshake is pending, so the opening cannot be
  consumed as silent note-on/note-off bursts. If an inactive browser window
  consumes the first click only for focus, repeated Play retries activation
  without cancelling the pending request and the UI explains what is needed.
  Portable journals now write and restore the legacy playing/recording slots as
  stopped process state while preserving the score cursor and view preferences.
- MusicXML performance dynamics retain exact per-onset velocity rather than
  being flattened to `p`/`mf`/`f`: export writes standard `<sound dynamics>`
  percentages and import gives those values precedence over the visible
  dynamic glyph. The current v10 opening candidate derives a restrained 52..93
  MIDI contour (37 distinct levels) from the retained source-audio envelope,
  preserves all 14 pedal events at 72/127, and renders its 192 attacks at
  -17.66 dBFS with zero sampler overloads. The Zig workbench's performance
  comparator independently measures normalized envelope, attack and sustain
  correlations plus onset matching. Against the former flat-velocity render,
  v10 improves those correlations from 0.311/0.294/0.660 to
  0.546/0.535/0.665, onset precision from 0.690 to 0.702, and normalized
  envelope error from 0.309 to 0.241. This repairs playback expression; it
  does not turn the still-unpromoted candidate into a certified transcription.
  A native autosave-recovery/export round trip preserves all 195 measures,
  2,760 events, 37 instrumental velocity levels, 14 pedal events, and the
  56.693% MusicXML damper value.
- Full-score expression no longer assumes that 790 score beats map rigidly onto
  the 332.7-second retained recording. The Zig workbench rebases the original
  193-measure timing ledger onto the two inserted opening measures, yielding
  195 anchors: new measures 1..14 end at 32.653 seconds and original measure 13
  resumes as measure 15 at 33.250 seconds. Anchor-aware shaping changes only
  performed velocity for the remaining 1,473 attacks. On complete matched
  renders, v11 improves envelope/attack/sustain correlations from
  0.243/0.233/0.192 to 0.718/0.697/0.666 and reduces normalized envelope error
  from 0.310 to 0.179. The 1,665-note render has zero overloads; native
  autosave/export recovery preserves all 40 velocity levels (52..94) and 14
  pedal events. Notes and the separate vocal guide remain subject to the
  measure-by-measure professional transcription gate.
- The consolidated Zig workbench now produces a per-measure, anchor-aware pitch
  ledger from three separated recording stems and can print competing pitches
  at every authored onset. Its first narrowly accepted correction replaces the
  stale target-measure-107 C/A-flat/E-flat cell with a playable D-flat/A-flat/F
  to G-flat transition while preserving timing, all 40 performed velocity
  levels, and all 14 MusicXML pedal events. Measure agreement rises from
  10%/20% exact/pitch-class to 80%/90%; whole-score exact and pitch-class
  matches each improve by seven at the same 120 ms gate. The resulting private
  v12 candidate hot-loads into the live Flecs world, renders 1,665 attacks in
  322.449 seconds through the 1,704-region grand at -16.58 dBFS, and reports no
  sampler drops or overloads. It is still `REVIEW_REQUIRED` pending a musician
  ear and keyboard pass.
- The following private v13 pass corrects measure 99's register and voicing at
  the same authored attacks: low G-flat2 supports an F4/A-flat4 then
  D-flat4/F4 figure instead of the thin G-flat3/D-flat5/A-flat5 loop. Local
  exact evidence rises 0/8 -> 8/8; full-score envelope, attack, sustain, and
  normalized-error metrics all improve over v12. A live three-second timing
  probe advances 7.412 beats at q=147, the GPU page is collision-free, and the
  immediate autosave/export recovery preserves 195 measures, 2,760 events, 40
  velocity levels, and 14 pedal events. Because most pitch evidence in this
  phrase comes from one separated guitar stem, it remains a review candidate.
- A proposed measure-92 correction demonstrates the rejection path: it reaches
  4/4 local exact matches with three corroborated attacks, yet lowers complete-
  render envelope and sustain correlations. Recomputing its four velocities
  from aligned accompaniment improves attack correlation only; the broader
  regressions remain. The live score therefore stays on v13 and the ignored v14
  candidate/report pair is retained solely as negative provenance.
- MusicXML pedal changes now have the same actual up/down semantics in native
  playback and offline verification: CC64 reaches zero, then returns to the
  authored depth after a one-millisecond render boundary. A conservative v15
  keeps v13's accepted events and adds only the missing terminal pedal-up,
  round-tripping 195 measures, 2,760 note/rest events, 40 velocity levels, 75
  harmonies, and 15 pedals. Its full corrected-semantics render is metric-
  identical to the fresh v13 baseline and has no overloads. Automatic
  measure/root/midpoint pedal plans with 96, 196, or 222 events are rejected:
  the frequent damper releases improve isolated onset precision but damage the
  whole-song sustain and envelope. This conservative v15 is the ignored local
  canonical study MXL and is byte-identical to the native live export.
- The Debug autosave has one authoritative writer. Only the host owning the
  local development-control socket may update `autosave-dev.score`; stale or
  duplicate comparison windows cannot overwrite it. A true cold restart with
  no score argument recovered the accepted v15 counts exactly, after which
  live Metal capture and sampler telemetry remained clean.
- Detailed pitch evidence now prints every active pitch per separated source
  at each authored onset, in addition to exact/pitch-class masks and
  corroborated candidates. This prevented an unsafe measure-64 rewrite where
  the supplied-page rest and sounding accompaniment intentionally differ. A
  source-plus-recording-supported measure-137 register candidate improves the
  pitch ledger but fails the complete-render envelope/attack gate, even after
  local anchor-aware velocity shaping, so it is not promoted.
- Private v17 makes only a three-pitch measure-174 correction supported by the
  retained recording stems: low A-flat2 under a playable
  E-flat4/A-flat4/D-flat5 voicing. It rejects a narrower two-edit attempt that
  created a 14-semitone hand span. The accepted candidate raises full-score
  exact/pitch-class matches to 1,088/1,443, passes the mechanical playability
  gate, and improves a freshly rerun same-reference full-song envelope,
  attack, sustain, and normalized-error comparison. The onset matcher retains
  790 matches but detects one additional candidate onset, a documented
  0.000535 precision tradeoff. Native engraving, sampled playback, exact MXL
  live round-trip, systems/WGSL reload, and sampler telemetry pass. The ignored
  accepted intermediate v17 MXL SHA-256 is
  `77ade1f49911291aa5f97ae75f73fc0bd3371e1062f71ecc7ff730a3217e2d22`.
- Private v18 retunes the same final E-flat4 to F4 in exact repeated phrases at
  measures 38 and 55. Different pairs of retained sources support F4 in both
  recording occurrences. The two-node edit improves the full exact,
  pitch-class, corroborated, envelope, attack, sustain, error, and matched-
  onset gates over v17 while preserving playability and every non-pitch
  property. Live sampled auditions and Metal captures pass at both phrases;
  native MXL export is byte-identical. The ignored canonical SHA-256 is
  `924edd2d067936a0c4255c4c3e5fa4076d7d813cd1ef4102fb9567df123e0a2c`.
- Private v19 removes two literal duplicate chord nodes at measure 62,
  beat 264: B-flat4 and D-flat5 were each encoded twice in the same right-hand
  voice. The consolidated Zig playability audit now reports duplicate
  same-voice pitch/onset groups, and its conservative `dedupe` transform only
  removes semantically identical instrumental copies; a regression test keeps
  separate voices and the vocal guide untouched. The canonical score is now
  2,758 events / 2,018 pitched / 1,663 instrumental / 485 vocal, with 195
  measures, 75 harmonies, 15 pedal events, and quarter-note = 147. It passes
  range, duration, density, one-octave span, and duplicate gates. Full
  three-source agreement rates improve slightly despite the smaller note
  denominator (exact 65.47% -> 65.48%, pitch-class 86.79% -> 86.83%); the
  322.449-second sampled render remains clean at -3.86 dBFS, and rounded
  whole-song performance metrics are unchanged. Native measure-62 playback,
  GPU engraving, hot system/WGSL reload, zero-fault sampler telemetry, and
  byte-identical live MXL export pass. The ignored v19 canonical SHA-256 is
  `8f4e0d9efdcbf59207912031b7a224b6726b8728603ded3e7657c4f825f574bd`.
- The playability report now separates visible dynamic glyphs from the actual
  performed velocity curve and audits sustain-pedal refresh semantics. v19 has
  40 performed velocity layers spanning MIDI 52..94, but its 15 pedal events
  include one second `start` while sustain is active and a 713.99-quarter-note
  gap before the final lift. It therefore remains explicitly interpretive
  `REVIEW_REQUIRED` even though its notes pass the mechanical gate.
- A conservative Zig-only v20 experiment preserves all existing pedal events,
  can normalize an active restart to a change, and inserts changes only at
  real instrumental attacks after a configured maximum gap. Complete 8-,
  12-, and 16-quarter-beat variants render with 103, 74, and 59 events and no
  sampler overloads. All are rejected: the best (12 beats) regresses retained-
  accompaniment envelope 0.687406 -> 0.644380, sustain 0.692831 -> 0.572780,
  and normalized error 0.185055 -> 0.205943 while reducing detected candidate
  onsets from 1,215 to 328. The ignored artifacts remain diagnostic evidence;
  canonical v19 is unchanged pending phrase/harmony-aware pedaling and an ear
  gate.
- Native guidance no longer presents the canonical 713.99-beat gap as a valid
  countdown. While an active sustain segment has no refresh within 16 quarter
  notes, the GPU footer shows `PEDAL PLAN REVIEW / LONG HOLD` in the warning
  color. Focused Zig tests and a live systems/WGSL hot reload at beat 262 prove
  the warning without changing playback or the private score.
- A v21 transform keys pedal changes to authored harmony identity and the first
  real instrumental attack, with a tested minimum refresh interval. It exposes
  that the imported harmony layer is itself incomplete: after the new opening,
  nearly every label through measure 91 is B-flat minor seventh and no harmony
  events exist beyond measure 91. Only three additional labeled changes can be
  justified. The min-4 candidate renders cleanly but regresses envelope
  0.687406 -> 0.676200, attack 0.589182 -> 0.569262, sustain 0.692831 ->
  0.680762, error 0.185055 -> 0.188025, and matched onsets 837 -> 801; its
  small onset-precision gain does not compensate. It is rejected and v19 stays
  canonical. Completing the harmony map is now a prerequisite for a credible
  phrase-aware pedal plan.
- The count-in footer explicitly says `N BEATS LEFT`. Its value continues to
  derive from the negative transport cursor and imported meter; a six-beat 6/4
  count-in captured near completion now reads `2 BEATS LEFT`, rather than the
  ambiguous `2 BEATS`.
- Debug audio evidence keeps its fixed-capacity score report on the heap, so a
  full-length WAV and MXL can be compared without overflowing the macOS Debug
  stack. Debug seek also leaves stale loop ranges and reports loop bounds;
  verified q=147 transport progression is 9.89 quarter beats in four seconds.
- The private authoring pipeline can apply STFT mixture-consistency projection
  to separated stem groups, preserving the lawful source mixture's complex
  phase while distributing separation residual by local spectral energy. The
  retained whole-mix and accompaniment audits feed a 24-phrase/193-measure
  verification ledger with timing/source provenance and explicit ambiguity
  lists; neither detector output nor page completeness certifies a phrase.
- Recording audit can rebase a numeric measure range onto a phrase-local audio
  excerpt. This makes opening/section A/B comparisons meaningful without
  warping the remainder of a full score into the excerpt; every result remains
  explicitly `REVIEW_REQUIRED` pending an ear and piano pass.
- A WebGPU-only Wasm/PWA export using Emdawnwebgpu, IndexedDB recovery, Service Worker offline caching, Web MIDI, getUserMedia, MediaRecorder, and a Zig DSP AudioWorklet. No Canvas 2D, WebGL, DOM product controls, or software renderer exists.
- A stable iOS C ABI plus device and simulator application bundles: CAMetalLayer rendering, AVAudioEngine synthesis/metronome/microphone capture, CoreMIDI, system document import/export, atomic recovery, Pencil/touch/mouse input, and external keyboard commands.
- MusicXML/XML, compressed MXL, standard MIDI, and backward-readable versioned
  `.score` v21 import. Version 21 adds a small portable reading-preference tail
  (view mode, zoom, reading position, tool, selected part, and visible practice
  panels) so native journals and browser IndexedDB recovery restore the actual
  workspace without serializing transient platform/device state;
  multi-part/polyphonic MusicXML timing; semantic explicit rests, tuplets,
  dynamics, slurs, articulations, fermatas, lyrics, and harmonies with tested
  MusicXML export/re-import; note edits with undo/redo; score-time-anchored
  pressure ink; measure-aware system layout; transport looping/count-in/metronome/tempo;
  synchronized audio/MIDI takes; and pitch/timing practice feedback.
- Score drawing and interaction share one imported-measure layout: note insert
  and selection hit-testing, annotation score-time anchors, playback following,
  seeking, and next/previous navigation all resolve authored system/page
  boundaries. Debug control exposes the same navigation for live Metal QA.
- Pagination is stage-height aware. A constrained score pane maps one complete
  system per page; a sufficiently tall pane maps two and distributes the
  second below the first system's complete glyph bounds. The same map drives
  page totals, navigation, playback following, annotations, selection, and
  edits. This removes the former next-system 4/4 collision and prevents paper
  or piano keys from extending into adjacent GPU panels. Native readbacks pass
  at 720x540 with the keyboard and 1440x900 with one- and two-system layouts.
- New ink stores an absolute quarter-note beat plus a normalized vertical
  location within its voice-plus-piano system. Rendering resolves that anchor
  through the current responsive page map, so the mark follows the same music
  when a former second system becomes a first system. A tag in the existing
  stroke page field keeps `.score` v15 binary layout stable; legacy page-space
  strokes still deserialize and render with their original semantics.
- Score zoom is layout-aware: the bounded system beat capacity and virtual
  engraving height vary from 45% through 105%, so zooming out reflows complete
  authored measures and successively adds complete systems to one paper sheet.
  Paged mode never stacks another page below or becomes a spread; continuous
  remains page-free and spread remains two-up. Rendering, playback following,
  page turns, annotation anchors, selection, and edit hit tests all use the
  same density. With piano and vocal guide visible at 1440x900, native Metal
  readbacks show one system at 100%, two on the same page at 65%, and four on
  the same page at 45%.
- Native PDF export builds every authored page with the same Zig/GPU draw
  packet used on screen, renders it to an offscreen Dawn/Metal BGRA target, and
  sends only the final pixels through the minimal CoreGraphics PDF sink. The
  result is an A4 document independent of the current viewport, page, and zoom;
  app chrome and playback highlights are excluded, and partial final pages use
  the same top-down system spacing as full pages.
- Piano systems use the Bravura SMuFL brace from the same generated MTSDF atlas
  as clefs and noteheads. Its GPU rectangle is derived from atlas plane bounds
  and spans the exact treble-to-bass staff height; the adjoining vertical staff
  connector remains an analytic primitive. This is verified in unit geometry
  and a real Dawn/Metal framebuffer at 65% overview zoom.
- Playback resolves connected MusicXML tie chains into one sustained sampler
  attack/release, while malformed dangling tie marks remain bounded and cannot
  leave a voice stuck.
- Score-authored pedal directions render in collision-aware expression lanes
  below the bass staff and drive a toggleable live/expected three-pedal guide;
  the same state is controllable from the GPU transport bar, keyboard,
  accessibility tree, and Debug hot-control channel.
- The GPU virtual piano derives current/next fingers from an allocation-free
  dynamic program over each hand's surrounding 24 score attacks. Direction,
  reachable span, stable repetitions, thumb crossings, phrase gaps, and
  black-key ergonomics are scored independently for left and right staff
  material; rests and the separately modeled vocal guide are excluded. The
  chord layer exhaustively assigns distinct fingers to every simultaneous tone
  in a playable one-to-five-note hand voicing, mirrors finger order between
  hands, and penalizes avoidable black-key thumbs; impossible >5-note hand
  clusters are visibly flagged for redistribution. Debug `fingering state`
  exposes the phrase anchors and `fingering chord` exposes every current/next
  pitch/finger pair used to compose the frame. Standard MusicXML
  `<technical><fingering>` values now import into the compact 32-byte Flecs
  note, survive `.score` v15 and MusicXML/MXL export/re-import, participate in
  undo/redo, and override only their matching phrase/chord tone. In Edit mode,
  `1`...`5` assigns the selected note and `0` restores automatic fingering;
  `fingering set NOTE_ID 1..5|clear` exposes the same operation to the live
  development socket. Version-14 journals migrate with automatic fingering.
  Native host QA loaded a five-note two-hand fixture, proved authored
  `5/4/3/5/4` guide assignments, changed note 1 live, exported MXL, re-imported
  the five standard fingering elements unchanged, and captured the Dawn/Metal
  framebuffer. The host then restored the ignored 193-measure private study,
  advanced playback from beat 716 to 717.267 at `1/8 = 147`, hot-reloaded both
  systems and WGSL, and retained zero sampler drops/overloads.
  Native Dawn/Metal readback at
  eighth=147 matched that state before and
  after a Flecs/WGSL reload and while playback advanced, with no sampler queue
  fault.
- Native playback uses pinned sfizz on the CoreAudio callback through a bounded
  SPSC MIDI queue. When the ignored Accurate-Salamander Grand V6.2beta2 pack is
  installed, its recommended 48 kHz/24-bit live SFZ (1,704 regions / 641
  preloaded samples) is selected; the 1,121-region Salamander V3 pack is the
  development fallback. Both remain optional local assets rather than silently
  bundled content, and an explicit `SCORE_INSTRUMENT`/`--sfz` override supports
  other instruments. The sfizz event argument is correctly treated as an
  intra-block sample delay—not a MIDI channel—so source-channel events enter at
  delay zero while channel identity remains in the portable model and exports.
  One studio profile enables its CC20...23 sampled release, hammer, pedal noise,
  and damper-resonance layers; the audio-thread-applied values are inspectable
  and adjustable live through the Debug control socket.
- `score-sampler-workbench verify` is an executable native acceptance gate, not a demo
  render. It checks silence/finite output, an eight-point velocity sweep,
  a seven-point continuous half-pedal curve, isolated sampled-release, hammer,
  pedal-mechanism and resonance A/B probes, repedaling, stable replay from fresh
  sampler instances, nonzero source-channel events, queue drops, and raw
  pre-limiter overload. It emits schema-2 JSON plus PCM16 WAV evidence and exits
  nonzero on failure. Both V6.2 and V3 permit legitimate sample variation, so
  replay is bounded by correlation and normalized error rather than falsely
  requiring every run to be bit-identical.
  The Accurate-Salamander live preset currently passes with a 33.478 dB measured
  velocity span, its documented CC64 curve, all four acoustic detail layers,
  6.235 dB greater held-note energy in the repedaled A/B probe, and zero drops
  or overloads under the stress chord across three consecutive gate runs.
- Standard MIDI import preserves ordered CC64/66/67 automation, continuous
  controller values, and PPQ timing. Type-1 tracks keep independent active-note
  state, malformed high-bit data bytes are rejected, and the imported pedal
  tail participates in document bounds and native sampler playback.
- MusicXML and Standard MIDI tempo changes are first-class score events. The
  Flecs transport consumes event boundaries without frame-size drift, the
  visible BPM remains an editable practice baseline that proportionally scales
  authored rubato, and MusicXML, MIDI, and `.score` v14 preserve the map.
  Printed metronome pulse and engine timing are distinct: MusicXML
  eighth=147 round-trips with `sound tempo=73.5`, while transport integration
  and Standard MIDI correctly use 73.5 quarter notes/minute.
- Standard MIDI export writes deterministic format-1 files at 480 PPQ with
  conductor metadata, a piano track, an optional vocal-guide track, connected
  tie chains, velocity/channel data, and ordered CC64/66/67 automation. Native
  export dispatches by `.musicxml`/`.xml`, `.mid`/`.midi`, or `.score` extension;
  an exported pedal fixture has been re-imported live with its beat-5 tail intact.
- Recorded MIDI takes export independently as deterministic format-1 files
  without notation quantization. The exporter converts the captured monotonic
  nanosecond timebase using the take's recorded tempo, preserves channel voice
  and continuous controller messages, and is available through GPU controls,
  accessibility, a native save panel, and the Debug control socket. Portable
  `.score` v14 persists the take tempo and raw events; a live note-plus-pedal
  take was saved, reloaded, and exported byte-identically.
- Standards-based MusicXML 4.0 export, metrical bar alignment even when an OMR
  measure is underfilled, semantic harmony import/persistence/GPU
  rendering/export, clef-aware seven-accidental key signatures, live MIDI
  CC64/66/67 pedal state, sustain and sostenuto semantics in the Zig diagnostic
  synth, and GPU three-pedal status. The diagnostic synth continuously scales
  release through CC64 0...63, decays held notes without re-attacking, supports
  envelope-safe repedaling, and resolves overlapping sustain/sostenuto state.
  Timed MusicXML sustain-pedal directions now
  survive `.score` v14 and MusicXML round trips, render as analytic pedal lines,
  drive native sampler CC64 playback, and provide a score marker against the
  continuous live hardware fill with late-transition practice feedback.
- Multi-part MusicXML export keeps the playable piano reduction and optional
  singer guide as separate score parts. The piano remains a braced two-staff
  instrument; the guide exports as its own labeled one-staff cue part and may be
  hidden without changing the piano notation. A live native export/re-import of
  the private 193-measure acceptance score preserves all 1,439 pitched piano
  events and all 355 pitched guide events. Its structural audit reports zero
  issues; 15 otherwise-empty guide measures gain explicit non-sounding rests.
- Imported measure maps are now first-class portable core data. MusicXML import,
  `.score` v14 persistence, hot-reloaded GPU UI, measure loops, bar/beat labels,
  metronome accents, and MusicXML export all retain pickups, irregular measure
  durations, source numbers, and mid-score meters. The private acceptance file
  round-trips as exactly 193 measures with all 17 time-signature entries instead
  of the former 171-bar fixed-4/4 reflow. The last 19 measures are a private,
  recording-gated repeat extension, not invented generic app content.
- Mid-system time signatures own horizontal engraving space. The opening meter
  remains in the fixed clef/key/meter lead, while a later meter change gives
  the affected measure a larger left content inset before beat one. The exact
  same inset is used by GPU note/rest placement and inverse pointer hit-testing,
  preventing the lower-staff 4/4 from colliding with notes while retaining the
  conventional meter on both staves of the grand staff. Unit coverage exercises
  a 2/4-to-4/4 transition, and native Dawn/Metal page-1 readback verifies the
  result with the optional vocal guide visible.
- Responsive pagination has no two-system special case. A bounded one-to-six
  system page map packs only complete authored measures, vertically justifies
  every visible system, and drives GPU engraving, page totals and turns,
  playback following, selection/insertion, and score-space ink. The optional
  vocal staff and lyric lane use their larger measured group extent. Zig tests
  exercise six piano systems and five voice-plus-piano systems; native Metal
  captures verify four and three respectively at 1400x1100.
- Concurrent MusicXML hairpins use deterministic interval-partitioned optical
  lanes keyed by part, staff, and above/below placement. Same-lane spans may be
  reused when their beat intervals do not overlap; simultaneous wedges receive
  22 px separation, clearing two maximum 9 px half-openings plus a 4 px optical
  gap. The six-lane resolver is bounded and allocation-free, and its live
  Dawn/Metal acceptance fixture shows two full-measure opposing wedges without
  visual merging.
- A shared instanced WGSL renderer with responsive desktop/iPad/phone layout and a generated original PWA/macOS icon.
- A core-owned semantic accessibility snapshot mirrored through NSAccessibility on macOS, hidden semantic DOM controls in the browser, and UIAccessibilityElement on iOS/iPadOS. Actions route back through the same Zig hit-testing path as pointer input.
- Native, web, and iOS build gates plus portable unit/integration tests and a pinned macOS CI workflow.

Release gaps are explicit rather than silently approximated: further
professional optical-engraving breadth, final editor/practice hardware QA,
advanced multi-mic concert-grand acoustics,
PDF page import/annotation, text/lasso
annotation tools, optional cloud sync, App Store provisioning, and production
content licensing remain open. The code must not describe those items as
complete until their acceptance tests pass.

The private, gitignored Holocene fixture is accepted as the current practice
baseline by explicit user direction, not represented as an authoritative
published transcription. Its
12-page OMR-derived core plus a separately gated repeated-finale extension are
useful for exercising import and playback,
and its meter/cursor structure now passes with zero structural issues. That
pass is deliberately separate from musical review: 265 inserted `<forward>`
spans initially identified unrecovered recognition time. Complete source-page
transcription of the dense page-8 accompaniment (P2 measures 98-114) removed 49
of those gaps. Complete source-page transcription of the page-9 piano part (P2
measures 115-130) removed another 26, including the changing second-half
voicings in measures 121-122 and the independent low E2 in measure 123.
Complete source-page transcription of page 10 (P2 measures 131-146) restored
the D/C accompaniment cells, corrected the C4 bass arrivals in measures
136-137, and rebuilt the 2/4 measure 138 through the 4/4 continuation. The
repair pipeline now also removes Audiveris's 24-unit phantom bar before that
2/4 transition, restoring the printed measure numbers for all later pages.
Complete page-11 transcription (P2 measures 147-164) restores the last
C5-G5-C5 cell, the full un-beamed right-hand figure, and every printed bass
quarter alternation. Complete page-12 transcription (P2 measures 165-174)
finishes six more two-hand figures, both arpeggiated half-note cadence bars,
and the tied low E2 close. A subsequent high-resolution review restores the
whole-note cadence sonorities that the combined OMR omitted in measures 37 and
96. Four gap-free, page-local rest-lane recoveries in piano measures 32, 35,
68, and 88 then improved the recording-alignment cost without changing the
priority distribution. Two later lyric-constrained, recording-gated donor
transplants, a four-measure combined gate, and a vocal-free accompaniment-led
bass repair bring the source-page core to 174 measures / 2,348 events. The
recording-backed final repeat extends the file to 193 measures / 2,564 events;
the later dual-reference measure-94 repair brings the live file to 2,575
events. The source ledger still retains 77 gaps across 62 part/measures, and 86
original Audiveris rhythm warnings remain in ignored JSON/Markdown ledgers.
Copied repeat bars inherit those review statuses. A separate 348-entry
part/measure review matrix records
133 page-complete entries, 215 entries requiring
page review, and zero recording-verified entries. The native renderer has also
survived ten consecutive combined system/WGSL hot reloads with clean text and
SMuFL output; atlas metadata changes are deliberately escalated to a host
rebuild/relaunch rather than allowed to sample a stale GPU texture.

A second, independent-page Audiveris 5.11.0 pass now validates every printed
page and system boundary before stitching. It preserves all 174 measures and
contains 527 voice plus 1,822 piano note/rest events, while explicitly logging
the removal of two shared 24/25-pixel non-pitched phantom slivers. After
normalization it still has 21 structural issues, 15 source rhythm warnings,
and 77 high-priority recording-review measures. Its lower global audio-alignment
cost is useful evidence, but those local failures prohibit promoting it over
the current private draft.
Authored page navigation was additionally exercised through the live control
socket on pages 42-44; a Metal readback of the short final page retained clean
text, SMuFL rests, and the tied closing E2 after the host rebuild. The short
page now draws only its populated system rather than a phantom empty staff.
The source is a voice/harp edition rather than a finished two-hand piano
reduction. It must not be called professional or accurate until every ledgered
gap and every musical symbol has been reviewed against the user-supplied pages
and the private reference recording. A user-authorized SoundCloud playback has
now been captured through BlackHole into ignored local content. The accepted
evidence timeline combines a main take, a clean retry anchored at 3:05, and a
trimmed cadence take anchored at 5:11. It covers 1,330 of 1,344 quarter-second
frames through 5:32.7 of the 5:35.827 track; the remaining 14 fade/silence
frames are explicit. The accidentally paused take and the raw cadence take
containing autoplay are excluded by filename and reason in the ledger.
A later browser-title-verified retry from the 3:05 marker independently matches
the accepted overlap at 0.868 chroma similarity. It remains corroborating
evidence rather than replacing the accepted segment because doing so worsened
the recording-alignment cost and review queue. The capture helper now rejects
prematurely-ended files before analysis as well as silent files.
A fresh browser-controlled retry after the user resumed SoundCloud contains no
internal silence after its 12.62-second pre-roll and matches the accepted
opening at 0.919838 chroma similarity with a 0.25-second content offset.
AVFoundation still ends at 298.494 seconds, before the displayed 5:35.827
duration, so the duration gate excludes the take and the accepted split/tail
timeline remains authoritative.
A later browser-controlled retry starts from a verified 0:00 and the official
player remains visibly active through 5:33, yet AVFoundation emits only
287.505 seconds. Its opening aligns to the accepted take at 0.855510 chroma
similarity with a 2.5-second content offset. The evidence ledger therefore
retains it only as corroborating review material and does not replace any
accepted segment.

The recording evidence also exposed a source-key error: the page-derived draft
was in C major while the recording and the user-supplied fragment are in
D-flat major. The private finalizer now transposes both accompaniment and
optional vocal guide up one semitone, writes a five-flat key signature, and is
idempotent. This changes the deterministic audio comparison from 39.45% to
65.26% pitch-class agreement and from 7.28% to 25.56% exact-pitch agreement;
it is strong evidence for the key correction, not proof of individual notes.
The accompaniment auditor now uses piecewise centers from 23 lyric anchors
agreed by independent score-text and page-OCR paths. Seventeen cover the page
core and six distinguish both final-refrain occurrences. This prevents the
repeated finger-picking pattern from jumping between verses; 21 anchors remain
inside their named measure and two are at most 0.52 seconds outside. Its local cost
also treats an empty reduction over strong audio as a mismatch instead of
rewarding silence. The corrected baseline is 0.330879 / 69 HIGH measures.
Review-only score-native transplants are kept in a separate MXL and must pass a
structural/recording gate before promotion. Measures 39<-110 and 63<-1 first
lowered cost to 0.328968 and HIGH measures to 67. A later combined candidate
38<-47, 62<-114, 64<-115, and 97<-147 passes the same gate, lowering cost to
0.327081 and HIGH measures to 64 while preserving all lyric-anchor diagnostics.
The four targets have 78.65%-100% pitch-class and 50%-100% bass agreement and
are still marked MANUAL, not certified. Measure 65's full-mix detector was
confounded by vocal overtones, so guitar/piano/other/bass stems were mixed into
a separate vocal-free accompaniment reference. Its A-flat/A-natural eighth-note
bass inflection and upper A-flat-E-flat-F figure pass the same gate at 100%
pitch-class / 100% bass agreement, reducing that audit from 0.315818 to
0.314392 and HIGH measures from 63 to 62. The full-mix result is retained too
(0.327166 / 63 HIGH, target MEDIUM). No aligned audible bar is now entirely
empty, but the score remains `REVIEW_REQUIRED` pending musician review.
The next dual-reference correction preserves the printed quarter-note rhythm
in measures 150 and 152 while retuning only their bass motion to A-A-A-Ab and
Gb-Gb-Gb-G. Both the whole mix (0.321189 / 61 HIGH) and vocal-free audit
(0.310129 / 60 HIGH) pass their strict gates; the two targets are MANUAL at
86.38%-93.71% pitch and 50%-72.73% bass agreement. Native Metal pagination
shows only the necessary natural/flat cancellations in the five-flat key.
Measure 60 then passes both gates with an even narrower edit: its existing two
half-note bass rhythm is retained and only B-flat/G-flat is retuned to
D-flat/F, the pitch classes independently present in the full mix and
vocal-free accompaniment. The whole-mix result is 0.321093 / 60 HIGH with
99.46% pitch and 75% bass agreement; vocal-free is 0.309862 / 59 HIGH with
99.39% pitch and 50% bass agreement. Native GPU capture, playback, sampler
telemetry, and MXL export/reimport all pass at 174 measures / 2,348 events.
The rhythm-preserving authoring path then retunes only the two existing lower
half notes in measure 133 from G-flat to A-flat. It leaves durations, rests,
beams, voices, staves, and every other part untouched. The full-mix gate reaches
0.318847 / 59 HIGH with 95.73% pitch and 100% bass agreement; the vocal-free
gate reaches 0.306919 / 58 HIGH with 95.8% pitch and 100% bass agreement. The
native Metal page at bar 133 renders cleanly and playback keeps the sampler at
zero drops and zero overloads.
The first recording-gated opening correction preserves both existing lower
eighth-note attacks in measure 5 and retunes only A-flat2/A-flat3 to
G-flat2/G-flat3. Whole-mix alignment improves 0.280010 to 0.279377 with HIGH
58 to 57 and the target at 83.27% pitch / 50% bass; the independent vocal-free
audit improves 0.263877 to 0.263063 with HIGH 57 to 56 and the target at 90.47%
pitch / 66.67% bass. The XML diff contains only those two pitch steps and an
explicit private evidence field. A measure-9 A-flat octave candidate initially
remained unpromoted because free whole-song DTW shifted adjacent measure 8 into
HIGH even though the local opening crop and vocal-free reference improved.
That boundary shift exposed a comparison flaw: two altered pitches could move
an otherwise unrelated repeated-phrase DTW path. The audit therefore supports
locked baseline measure windows. Candidate pitches are scored inside the exact
same recording windows as the current score, and a regression test proves they
cannot retime other measures. Free-DTW reports remain useful diagnostics, but
promotion deltas now use like-for-like locked mappings.

With that correction, opening measure 3's A-flat2/A-flat3 candidate passes both
independent references and the bounded phrase audit. Locked whole-mix cost
improves 0.319907 to 0.318745 with HIGH 63 to 62 and target agreement 82.71%
pitch / 100% bass; locked vocal-free cost improves 0.292284 to 0.291094 with
HIGH 60 to 59 and 94.71% pitch / 100% bass. The 12-measure crop improves
0.272430 to 0.249940 and HIGH 7 to 6. Only B-flat2/B-flat3 become
A-flat2/A-flat3; rhythm, rests, voice/staff assignment, and all non-target XML
are identical. Native Metal playback at bar 3 retains eighth=147 timing and
zero sampler faults. A measure-2 F2/F3 hypothesis is rejected because the
whole-mix cost and HIGH count worsen and vocal-free bass agreement remains 0%.
The same locked-window method then clears measure 9 without moving measure 8:
G-flat2/G-flat3 become A-flat2/A-flat3, locked whole-mix cost improves 0.318745
to 0.317536 with HIGH 62 to 61 and 88.86% pitch / 75% bass, and locked
vocal-free cost improves 0.291094 to 0.289975 with HIGH 59 to 58 and 78% pitch
/ 75% bass. The bounded opening cost reaches 0.241808 with HIGH 5. Exact-tree
comparison again limits the edit to two pitch nodes plus private provenance.
The following opening correction treats measure 10 as a complete piano texture
instead of optimizing an isolated lower octave. Its five existing right-hand
attacks become F4-D-flat4-D-flat4-F4-D-flat4 and its two existing left-hand
attacks become A-flat2-B-flat2, with every onset, duration, rest, beam, voice,
and staff retained. Locked whole-mix cost improves 0.317536 to 0.314599 with
HIGH 61 to 60 and target agreement 95.24% pitch / 80% bass. Locked
accompaniment cost improves 0.289975 to 0.286912 with HIGH 58 to 57 and 85.17%
pitch / 50% bass; the 12-measure opening cost reaches 0.217273 with only three
HIGH bars. A canonical semantic comparison masks only those seven pitches and
the two new private provenance fields, then proves the complete remaining XML
identical. The audit report now stores its exact evidence path because three
similarly named accompaniment analyses intentionally produce different
metrics; candidate promotion can no longer rely on an implicit filename.
Native M3 Max Metal readback at bar 10 is clean, playback advances 2.48 quarter
beats in two seconds at eighth=147, and the 1,704-region sampler stays at zero
drops/overloads. Native export/re-import remains structurally clean with 193
measures, a separate 1,439-note/two-staff piano part, and an optional vocal
guide containing 355 pitched notes plus 468 cues. This is still
`REVIEW_REQUIRED`, not a professional musical certification.
Measure 11 follows with F4-D-flat4-D-flat4-F4-F4 over B-flat2/B-flat3, again
retuning only existing attacks. Locked whole-mix cost improves 0.314599 to
0.312613 and the target moves MEDIUM to MANUAL at 100% pitch / 75% bass while
the global HIGH count stays at 60. Locked accompaniment improves 0.286912 to
0.285514 and HIGH 57 to 56, with the target HIGH to MANUAL at 87.66% pitch /
75% bass. The bounded opening cost improves 0.217273 to 0.208844 without
increasing its three HIGH bars. The promotion gate therefore implements an
explicit Pareto rule: alignment cost and HIGH count cannot regress, at least
one must strictly improve, and all unchanged local two-hand/pitch/bass gates
must pass. This handles a MEDIUM-to-MANUAL correction without pretending it
removed an unrelated HIGH bar. Exact-tree masking limits the score change to
six pitch nodes and two private evidence fields. Native Metal rendering and
playback at bar 11 remain clean at eighth=147 with zero sampler faults.
An earlier opening bar then clears with only two changed pitches. In measure 8,
the first upper A-flat4 becomes F4 and the second lower B-flat3 becomes
A-flat3; the remaining A-flat/F upper figure and initial B-flat2 are retained.
Time-resolved guitar, piano, and other-stem events independently support this
mixed contour. Locked whole-mix cost improves 0.312613 to 0.311322 and HIGH 60
to 59, with the target HIGH to MANUAL at 92.10% pitch / 60% bass. Locked
accompaniment improves 0.285514 to 0.284850 with HIGH unchanged at 56 and the
target MEDIUM to MANUAL at 95.75% pitch / 50% bass. The bounded opening remains
MANUAL at 100% pitch / 100% bass and improves to 0.206276. Exact-tree masking
proves every non-target semantic node unchanged; native Metal rendering and
sampled playback at bar 8 are clean. Measures 6, 7, and 12 are deliberately
not force-cleared: their fixed whole-mix and accompaniment bass frames conflict,
and no two-attack preserved-rhythm pair reaches the unchanged local threshold
in both references. Extra attacks and relaxed gates are not substituted for a
musician decision.
The first later dual-HIGH bar then clears through an even narrower correction.
Measure 50 retains its complete upper voice and rhythm; only B-flat2/B-flat3
become A-flat2/A-flat3. Both fixed references and time-resolved guitar, piano,
and other-stem events sustain A-flat through those attacks. Five plausible
upper-voice alternatives were evaluated and all score worse than retaining the
authored line. Locked whole-mix cost improves 0.311322 to 0.310638 and HIGH 59
to 58 with target agreement 92.73% pitch / 100% bass. Locked accompaniment
improves 0.284850 to 0.283416 and HIGH 56 to 55 with 91.49% pitch / 100% bass.
Canonical diffing proves only two pitch nodes and one private provenance field
change. Native Metal readback/playback at bar 50 is clean at eighth=147 and the
sampled grand reports zero queue or overload faults.
Measure 59 is the next complete two-hand correction. Its existing five upper
attacks are retuned to G-flat4-D-flat4-D-flat4-A-flat4-A-flat4 and its two
lower attacks to B-flat2/G-flat3 without changing any rhythm, rest, beam,
voice, or staff. Half-beat evidence from the locked whole mix, accepted
accompaniment, and separated guitar/other events supports the contour; three
weaker preserved-rhythm variants remain diagnostic only. The whole-mix gate
improves 0.310638 to 0.308245 and HIGH 58 to 57, while the accompaniment gate
improves 0.283416 to 0.280379 and HIGH 55 to 54. Measure 59 becomes MANUAL in
both reports at 100% pitch-class and 66.67% bass agreement. Canonical diffing
confines the score change to its seven pitch nodes plus private provenance;
all 2,575 note/rest events remain intact. Native Metal readback/playback,
MusicXML export/re-import, systems/WGSL hot reload, the Accurate-Salamander
V6.2 offline sampler gate, and strict ReleaseSafe arm64 bundle signing all
pass without queue drops, overloads, clipping, or shader fallback. The result
is still `REVIEW_REQUIRED` until a musician adjudicates its voicing, fingering,
dynamics, articulation, pedal, and sound at the piano.
The following 2/4 bar, measure 66, receives an even narrower correction. Its
first upper A-flat4 becomes F4 while the supported second A-flat4 remains, and
the two lower attacks become A2/A-flat3. The apparent chromatic bass follows
the time-resolved evidence: the locked whole mix begins on A2 and reaches
A-flat3, while the accepted accompaniment sustains A-flat. Whole-mix cost
improves 0.308245 to 0.307313 and HIGH 57 to 56 with 87.16% pitch / 66.67%
bass; accompaniment cost improves 0.280379 to 0.279697 and HIGH 54 to 53 with
85.85% pitch / 66.67% bass. Canonical diffing finds exactly three pitch-node
changes and no rhythmic or structural mutation. Native Metal readback,
playback, export/re-import, systems/WGSL reload, sampled-grand telemetry, and
the Python/Zig suites pass. The bar remains `REVIEW_REQUIRED` for a musician's
voicing, fingering, dynamics, articulation, pedal, and final ear decision.
Measure 72 then replaces the unsupported G-flat lower octave with
B-flat2/B-flat3 and uses the preserved upper contour
B-flat4-B-flat4-D-flat4-F4-D-flat4. Both fixed references and the separated
guitar support B-flat; four upper variants pass structural comparison and are
kept as diagnostics. The selected one is not the numerically cheapest: it
retains the authored quarter-note F4 because Basic Pitch detects that event
continuously from 121.681 to 122.180 seconds. Whole-mix cost improves 0.307313
to 0.305325 and HIGH 56 to 55 at 94.35% pitch / 100% bass; accompaniment cost
improves 0.279697 to 0.277542 and HIGH 53 to 52 at 96.23% pitch / 100% bass.
Six pitch nodes change while all onsets, rests, durations, voices, staves,
beams, and the 2,575-event document remain intact. Native Metal rendering,
playback, export/re-import, stateful systems/WGSL reload, and sampled-grand
telemetry pass. This bar also remains `REVIEW_REQUIRED` for musician review.
Measure 76 is deliberately not changed. Its locked whole-mix fundamentals move
from G-flat to C while the accepted accompaniment moves from C to D-flat, but
the higher-resolution guitar transcription repeatedly reports D-flat3 through
the relevant 126.002-126.873-second span. A diagnostic C3/C3 replacement is
the only frame-threshold compromise: it clears the whole-mix HIGH bar without
changing global cost, but worsens accompaniment cost 0.277542 to 0.277805 and
therefore fails the unchanged Pareto gate. The authored D-flat figure remains
`HIGH` / `REVIEW_REQUIRED` pending improved alignment or musician adjudication;
the implementation does not turn detector disagreement into a false edit.
Measure 96 supplies the next convergent sustained-bass correction. Its existing
four-quarter A-flat3/D-flat4 upper dyad remains intact and only the lower whole
note moves from D-flat3 to G-flat2. Both locked recording references sustain
G-flat through the bar. Whole-mix cost improves 0.305325 to 0.304103 and HIGH
55 to 54 with 93.17% pitch / 66.67% bass agreement; accompaniment cost improves
0.277542 to 0.276789 and HIGH 52 to 51 with 97.41% pitch / 75% bass agreement.
Canonical diffing finds one P2/m96 pitch change and no timing, voice, staff, or
event-count mutation. Native Metal page-24 readback/playback, systems/WGSL hot
reload, eighth=147 transport, fingering, and the 1,704-region sampled grand are
clean. Export/re-import preserves all 1,439 pitched piano and 355 pitched vocal
events; the exporter additionally writes 15 standard full-measure rests into
otherwise empty vocal-guide bars. The bar remains `REVIEW_REQUIRED` pending a
musician's voicing, fingering, dynamics, articulation, pedal, and ear decision.
The next flagged bar demonstrates why the gates are necessary but not
sufficient. Measure 102's musically plausible octave correction,
B-flat2-F3-B-flat2-F3, agrees with the five-flat key, secondary page, and
separated guitar, yet fails the unchanged local thresholds: the whole mix
reaches only 72.54% pitch / 25% bass and accompaniment remains HIGH at 61.28%
pitch / 14.29% bass. A detector-led A-natural2-F3-A-flat2-E-flat3 alternative
passes numerically, but its chromatic A-natural contradicts that independent
musical evidence. It is retained only as a diagnostic; m102 stays `HIGH` /
`REVIEW_REQUIRED` pending better alignment or musician adjudication.
Measure 103 then converges on a complete D-flat-major sonority over A-flat.
The repeated upper B-flat4 attacks become F4 while both D-flat5 attacks remain;
the lower B-flat3/F4 pairs become A-flat2/A-flat3. The recording frames and
separated guitar sustain A-flat, D-flat, and F, so this full chord is selected
over third-less or detector-only variants. Whole-mix cost improves 0.304103 to
0.302313 and HIGH 54 to 53 at 84.15% pitch / 85.71% bass; accompaniment cost
improves 0.276789 to 0.274686 and HIGH 51 to 50 at 79.52% pitch / 100% bass.
Exact event comparison confines the edit to six P2/m103 pitches with every
rest, onset, duration, beam, voice, staff, and all 2,575 events unchanged.
Native Metal page-26 rendering, fingering, sampled playback, MusicXML
export/re-import, systems/WGSL hot reload, and the Python/Zig suites pass with
zero sampler queue faults. The bar remains `REVIEW_REQUIRED` for musician
voicing, fingering, dynamics, articulation, pedal, and final ear confirmation.
Measure 106 resolves the next dense arpeggio as a playable G-flat-major-seventh
spread. Its existing lower simultaneous attack becomes G-flat2+B-flat3,
followed by D-flat4; the existing upper pair becomes D-flat4-F4, and that
complete figure repeats after the authored quarter rest. Locked frames and
separated guitar events independently contain G-flat, B-flat, D-flat, and F.
Twelve same-rhythm distributions were evaluated; the selected one retains the
third and seventh and is the musically complete dual-gate pass. Whole-mix cost
improves 0.302313 to 0.301416 and HIGH 53 to 52 at 80.09% pitch / 66.67% bass;
accompaniment improves 0.274686 to 0.273175 and HIGH 50 to 49 at 92.98% pitch /
100% bass. Exact event comparison confines the edit to ten P2/m106 pitch nodes
and keeps all 2,575 notes/rests plus every onset, duration, chord flag, rest,
beam, voice, and staff intact. Native Metal page-27 rendering, fingering,
sampled playback, MusicXML export/re-import, systems/WGSL reload, and automated
tests pass without sampler queue faults. The result remains `REVIEW_REQUIRED`
for musician voicing, fingering, dynamics, articulation, pedal, and ear review.
Measure 110 becomes a D-flat/add-nine color over A-flat using the same authored
chord-plus-arpeggio rhythm. Each lower simultaneous attack is retuned to
A-flat2+E-flat3 and followed by D-flat4; the upper pair becomes A-flat3-F4.
Locked frames and separated guitar repeatedly contain all four pitch classes.
Ten complete distributions were gated, and this is the only musically coherent
dual pass. Whole-mix cost improves 0.301416 to 0.299985 and HIGH 52 to 51 at
79.72% pitch / 100% bass; accompaniment improves 0.273175 to 0.272603 and HIGH
49 to 48 at 79.41% pitch / 50% bass. Exact event comparison finds ten P2/m110
pitch changes, no non-pitch changes, and the same 2,575 notes/rests. Native
Metal page-28 rendering, fingering, sampled playback, MXL export/re-import,
systems/WGSL hot reload, and automated tests pass without sampler queue faults.
The bar stays `REVIEW_REQUIRED` pending musician voicing, fingering, dynamics,
articulation, pedal, and final ear review.
The adjacent measure 111 is intentionally not forced into the same voicing.
Its locked bass frames alternate A-flat, A-natural, E-flat, and D-natural.
The repeated m110 figure plus seven complete diatonic D-flat/add-nine and
F-minor-seven distributions were gated; none clears both local references.
The strongest full-mix F-minor candidate reaches 68.28% pitch / 50% bass while
accompaniment reaches only 66.68% pitch / 25% bass. The source bar therefore
remains `HIGH` / `REVIEW_REQUIRED` pending improved alignment or musician
adjudication; chromatic detector noise is not promoted into the score.

Measure 114 resolves as a time-varying transition rather than a repeated static
voicing. Its existing lower eighth-note pairs become B-flat2-D-flat4 followed
by C3-B-flat3, while the existing upper pairs are B-flat4-D-flat5 followed by
A-flat4-D-flat5. This captures the common B-flat/D-flat opening, the C bass in
the vocal-free frames, and the later B-flat/A-flat/D-flat material across the
full mix and separated guitar/other/piano events. Nine complete same-rhythm
controls were gated. The selected shell improves locked whole-mix cost from
0.299985 to 0.299385 and HIGH 51 to 50 at 79.89% pitch / 66.67% bass;
vocal-free cost improves from 0.272603 to 0.272299 and HIGH 48 to 47 at 78.47%
pitch / 60% bass. Exact formatted-XML and event-ledger comparison proves that
only four P2/m114 pitches and two private provenance fields changed. A first
generic voice rewrite was discarded because it added redundant stem nodes;
the promoted MXL was rebuilt with the rhythm-preserving retuner. Native Metal
page-29 rendering, fingering, sampled playback at eighth=147, MXL
export/re-import matched by semantic part name, systems/WGSL hot reload, the
1,704-region grand-piano sampler, Python tests, and Zig tests all pass without
sampler drops or overloads. The result remains `REVIEW_REQUIRED` pending a
musician's voicing, fingering, dynamics, articulation, pedal, and ear review.

Measure 115 uses the same authored broken-chord rhythm but changes bass harmony
inside the bar. Its first lower pair is D-flat3-D-flat4 and its second is
A-flat2-A-flat3; both upper pairs are A-flat4-D-flat5. Six static/register
controls showed why the split matters: the locked full mix begins on D-flat
before settling onto the A-flat bass that dominates the separated guitar and
vocal-free frames. The accepted candidate improves locked whole-mix cost from
0.299385 to 0.296574 and HIGH 50 to 49 at 87.02% pitch / 71.43% bass;
vocal-free cost improves from 0.272299 to 0.269897 and HIGH 47 to 46 at 94.18%
pitch / 100% bass. Exact formatted-XML comparison limits the promotion to six
P2/m115 pitch nodes and two private evidence fields. Native Metal page-29
rendering, two-hand fingering, sampled playback at eighth=147, semantic
MusicXML/MXL export/re-import, systems/WGSL reload, and sampler telemetry all
pass without drops or overloads. The bar remains `REVIEW_REQUIRED` for a
musician's voicing, fingering, dynamics, articulation, pedal, and ear review.

Measure 124 is a layered reduction rather than a choice between competing bass
detectors. The isolated piano sustains F3 while the guitar sustains B-flat3, so
the existing two left-hand half notes become F3+B-flat3 dyads and the authored
upper E-flat5-A-flat5-F5 figures remain unchanged. Seven single-bass and
alternate-upper controls each dropped one simultaneous layer and missed the
vocal-free bass gate by one mapped frame. The complete dyad improves locked
whole-mix cost from 0.296574 to 0.296037 and HIGH 49 to 48 at 81.54% pitch /
100% bass; vocal-free cost improves from 0.269897 to 0.268431 and HIGH 46 to 45
at 97.58% pitch / 85.71% bass. The exact XML diff retunes the two original bass
notes, adds one chord tone at each existing onset, and records one private
evidence field, intentionally increasing the score from 2,575 to 2,577 events.
Native Metal page-31 engraving, F3(5)-B-flat3(2) fingering, sampled playback,
semantic MXL export/re-import, systems/WGSL reload, and sampler telemetry all
pass. The bar stays `REVIEW_REQUIRED` for musician voicing, dynamics,
articulation, pedal, and ear review.

Measure 131 preserves the existing E-flat5-A-flat5-F5 right-hand figure and
reconstructs the two sustained left-hand attacks as D-flat/F/A-flat shells.
The full locked recording repeatedly supports F, D-flat, and A-flat, while
separated guitar sustains D-flat4/A-flat3/F4 and separated piano independently
supports F4. A-flat-only and A-flat/D-flat controls were rejected because they
failed at least one local reference. The complete shell improves locked
whole-mix cost from 0.296037 to 0.293537 and HIGH 48 to 47 at 100% pitch / 100%
bass; vocal-free cost improves from 0.268431 to 0.265771 and HIGH 45 to 44 at
97.55% pitch / 50% bass. Exact XML comparison finds only two B-flat3-to-A-flat3
retunes, four new chord-tone nodes at the existing two half-note onsets, and
one private provenance field, increasing the private document from 2,577 to
2,581 events. Native page-33 GPU readback, D-flat4/F4/A-flat3 fingering,
eighth=147 playback timing, semantic MXL export/re-import, systems/WGSL reload,
and the 1,704-region sampler all pass without queue drops or overloads. The bar
remains `REVIEW_REQUIRED` for musician voicing, dynamics, articulation, pedal,
and final ear review.

The review-only voice authoring helper now omits stems unless a replacement or
event explicitly requests one. This keeps chord candidates from adding
redundant notation nodes to source voices that intentionally rely on engraving
defaults; regression tests cover both omitted and explicitly authored stems.

The accepted recording continues through a second final refrain that is absent
after the supplied page-12 double bar. Sparse-layout OCR recovers the page-11
and page-12 lyric lanes, and page-local ASR windows independently distinguish
the first occurrence (measures 156/164/169 at 258.47/273.79/279.39 seconds)
from the second (appended 175/183/188 at 288.84/304.79/316.21 seconds). A
review-only authoring tool copies both voice guide and piano measures 156-174
exactly to 175-193 and moves the terminal barline to the new ending. Its
dedicated dual-reference gate passes with 23 anchors, complete recording-end
coverage, unchanged 0.52-second maximum anchor deviation, and normalized costs
0.296776 full mix / 0.279735 vocal-free. The live native app and its exported
MXL both re-import as 193 measures / 2,564 events with 1,785 pitched events;
pages 44-49 render cleanly, end playback stops at beat 756, and sampler faults
remain zero. This closes the structural missing-repeat gap but leaves every
copied note, transition, dynamic, articulation, pedal, and tempo choice
`REVIEW_REQUIRED` for a musician.
Recording-led review of the two final-refrain occurrences then corrects five
existing lower-staff bars without changing rhythm or structure. Measures
159/178 use B-flat2/F3 instead of the OCR draft's G-flat/D-flat, with an E-flat3
approach only in the second occurrence; measures 161/180 use A-flat octaves;
and later measure 185 independently uses A-flat octaves. Applying the same last
edit to source measure 166 is rejected because its bass agreement remains zero,
so the recording—not the copied page pattern—decides. The combined whole-mix
gate improves 0.296776 -> 0.284912 and 70 -> 64 HIGH bars; the vocal-free gate
improves 0.279735 -> 0.268818 and 68 -> 63 HIGH bars. All five accepted targets
are two-hand MANUAL bars with 86.52%-100% pitch and 50%-100% bass agreement.
Native GPU captures on pages 40 and 45 are clean; native export/reimport retains
193 measures / 2,564 events at eighth=147 (73.5 QPM) with zero sampler faults.
Post-unpause SoundCloud diagnostics preserve the accepted split timeline. One
clean retry has no internal pause but ends at 298.494 seconds and matches the
accepted opening at 0.919838 chroma similarity; a second ends at 297.459
seconds. A nominally 340-second experiment is rejected after the UI reveals a
hidden 30-second ad and ASR places its audio near 1:26, and a real-opening
routing probe is rejected at -91 dBFS silence. The capture path does not smooth
timestamp gaps or invent the missing tail merely to satisfy a duration check.
The next lower-staff review at measure 132 deliberately stops without editing
the private score. Four rhythm-preserving G/A-flat half-note candidates reduce
the global HIGH queue, but no candidate passes both local references: A-flat
octaves pass only the vocal-free target gate, while all four fail the whole-mix
target pitch threshold. The existing G-flat octaves therefore remain
`REVIEW_REQUIRED`; a lower aggregate cost is not treated as musical proof.
Measure 136 reaches the same conservative conclusion for a different reason.
Its upper E-flat/A-flat/F figure already reaches 94.08% accompaniment pitch
agreement, while the two authored D-flat bass notes have zero agreement. Seven
same-rhythm lower-line controls were gated. B-flat3/A-flat2 is strongest in the
whole mix (70.29% pitch / 50% bass and HIGH 47 to 46) but substantially regresses
the vocal-free reference; A-flat2/D-flat4 retains 94.08% pitch / 100% bass in
the vocal-free window but fails the whole mix. Since no candidate clears both
locked references, measure 136 remains unchanged and `REVIEW_REQUIRED`.
Measure 138 resolves as a sustained D-flat/F/A-flat left-hand shell under the
existing E-flat5-A-flat5-F5 upper figure. Separated guitar and the two locked
references repeatedly support D-flat, F, and A-flat; the whole-mix bass favors
F3 while accompaniment favors A-flat3. Eight register and completeness controls
were gated with the same 23 timing anchors. F3-A-flat3-D-flat4 strictly
dominates the other dual passes: whole-mix cost improves 0.293537 to 0.292779
and HIGH 47 to 46 at 100% pitch / 50% bass, while accompaniment improves
0.265771 to 0.264673 and HIGH 44 to 43 at 100% pitch / 100% bass. Exact XML
comparison limits the change to one B-flat3-to-F3 retune, two chord tones at the
same half-note onset, and one private provenance field, increasing the score
from 2,581 to 2,583 events. Native page-35 GPU readback verifies the 2/4 meter
clearance and 5-4-2 left-hand guide; one-second playback advances 1.253 quarter
beats against 1.225 expected, sampler faults remain zero, and semantic
MusicXML/MXL export/reimport preserves all seven piano events despite normalized
part IDs. The bar remains `REVIEW_REQUIRED` for musician voicing, dynamics,
articulation, pedal, and final ear review.
Measure 139 does not resolve under the same gate. Seven A-flat-rooted dyad and
shell candidates follow the separated guitar's A-flat/E-flat/F first half and
A-flat/D-flat/F second half; they reach as high as 100% pitch agreement and
improve both global costs and HIGH queues, but only 28.57% whole-mix / 33.33%
accompaniment bass agreement. Five G/G-flat motion controls test the conflicting
mixture bass detections without treating them as truth. G3-to-A-flat3 is the
only whole-mix pass and fails accompaniment with zero bass agreement. No
candidate clears both locked references, so measure 139 remains unchanged,
`HIGH`, and `REVIEW_REQUIRED` rather than acquiring detector-led chromatic
notes unsupported by the separated instruments.
Measure 140 is likewise held. Six A-flat/D-flat/F register and time-resolved
controls all pass the vocal-free reference, reaching 100% pitch / 100% bass,
but remain at 20% whole-mix bass agreement because those frames are dominated
by A-natural2. That pitch is absent from the separated guitar/piano and the
vocal-free bass, so it is treated as full-mix contamination rather than a
sustained chromatic piano note. Measure 140 stays unchanged, `HIGH`, and
`REVIEW_REQUIRED` pending cleaner evidence or musician adjudication.
Measure 150 replaces the contradicted A-natural/A-flat lower line with four
playable B-flat2-F3-B-flat3 quarter-note shells. Both locked references and the
separated guitar support B-flat/F. The selected octave-and-fifth voicing is
preferred over a slightly cheaper D-flat extension because that extension
forms an impractical left-hand tenth and has weaker direct stem support.
Whole-mix cost falls 0.292779 to 0.290657 and HIGH 46 to 45 at 93.61% pitch /
50% bass; accompaniment falls 0.264673 to 0.263269 and HIGH 43 to 42 at 99.13%
pitch / 71.43% bass. Only m150 changes semantically and the added chord tones
grow the score from 2,583 to 2,591 events. Native Metal readback, 5-3-1
fingering, eighth=147 playback, normalized semantic export/reimport, WGSL
reload, and sampler telemetry all pass with zero faults.
Measure 151 then follows the audible harmonic transition with B-flat2-F3 dyads
for its first two quarter attacks and A-flat2-E-flat3 dyads for the last two.
This is the only one of seven static, shell, and time-resolved controls that
passes both locked gates: whole-mix cost 0.290657 to 0.289700, HIGH 45 to 44,
91.49% pitch / 50% bass; accompaniment cost 0.263269 to 0.261618, HIGH 42 to
41, 90.89% pitch / 64.29% bass. The exact semantic diff is confined to m151,
the document grows from 2,591 to 2,595 events, and strong dual-reference
coverage reaches 61 measures. Native page-38 engraving, playback, guided
fingering, semantic MXL export/reimport, WGSL reload, and the 1,704-region
sampled grand pass without drops or overloads. Both bars remain
`REVIEW_REQUIRED` for musician voicing, dynamics, articulation, pedal, and
final ear adjudication.
Measure 152 remains deliberately unpromoted. Its directly supported
A-flat2-A-flat2-A-flat2-A2 correction, its octave realization, and a fifth-shell
control all pass the vocal-free reference, but the first two miss the unchanged
whole-mix bass gate by one 250 ms frame: 41.67% versus 45%. The full-mix cost
and HIGH queue still improve substantially, but the process does not weaken a
local gate or invent an unsupported G pitch to turn a near miss into a pass.
The current bar remains `HIGH` pending cleaner alignment or musician review.
Measure 153 is a cleaner semitone error. Its four existing alternating
B-flat2/B-flat3 quarter notes become A2/A3 without changing rhythm, texture, or
event count. Both locked gates pass: whole-mix cost 0.289700 to 0.287885 and
HIGH 44 to 43 at 81.93% pitch / 57.14% bass; accompaniment cost 0.261618 to
0.260527 and HIGH 41 to 40 at 90.17% pitch / 58.33% bass. Exact comparison
finds only four m153 pitch-node changes. Native page-39 rendering, octave
fingering, eighth=147 playback, normalized semantic MXL export/reimport, WGSL
reload, and the sampled grand pass without faults; strong dual-reference
coverage reaches 62 measures. The bar remains `REVIEW_REQUIRED` for musician
dynamics, articulation, pedal, and final ear adjudication.
Measure 155 remains unresolved after six E-flat/G-flat transition, octave, and
shell controls. Every playable line worsens both locked global costs, while the
only accompaniment pass is an unplayable 18-semitone diagnostic shell. Measure
160 likewise stays unchanged after five time-resolved F/E-flat/A controls: the
best full-mix line misses the bass gate by one mapped frame at 42.86%, and the
remaining accompaniment passes either regress whole mix or fail its local
threshold. Neither bar is changed merely to reduce a local HIGH count.
Measure 163 supplies the next convergent correction. Its four alternating
A-flat2/A-flat3 quarter notes become G-flat2/G-flat3, preserving rhythm,
texture, and event count. Whole-mix cost falls 0.287885 to 0.286583 and HIGH 43
to 42 at 79.07% pitch / 83.33% bass; accompaniment falls 0.260527 to 0.259538
and HIGH 40 to 39 at 77.66% pitch / 71.43% bass. Exact comparison finds only
four pitch-node changes. Native page-41 rendering, octave fingering,
eighth=147 playback, normalized semantic MXL export/reimport, WGSL reload, and
the sampled grand pass without faults; strong dual-reference coverage reaches
63 measures. The bar remains `REVIEW_REQUIRED` for musician dynamics,
articulation, pedal, and final ear adjudication.
Measure 165 remains unresolved after four time-resolved and common-class
controls. None clears both local gates, and the direct D-flat/C/D/C frame
sequence slightly worsens accompaniment cost. Measure 166 does converge after
distinguishing a chromatic pickup from a repeating pattern: one D3 quarter is
followed by three E-flat3 quarters. Static E-flat misses whole mix by one frame;
alternating D/E-flat passes but overstates the separated-stem D onset. The
tightened line improves whole-mix cost 0.286583 to 0.285635 and HIGH 42 to 41
at 86.81% pitch / 50% bass, and accompaniment cost 0.259538 to 0.258985 and
HIGH 39 to 38 at 88.80% pitch / 50% bass. Exact comparison changes only four
pitch nodes. Native page-42 rendering, fingering, eighth=147 playback,
normalized semantic MXL export/reimport, WGSL reload, and sampler telemetry
pass without faults; strong dual-reference coverage reaches 64 measures. The
bar remains `REVIEW_REQUIRED` for musician dynamics, articulation, pedal, and
final ear adjudication.
Measure 177 resolves a different late-repeat bass texture rather than blindly
copying its source bar. Six plausible register and alternating-line controls
either regress a locked cost or miss the bass threshold. The separated stems
and the intersection of both fixed frame mappings instead support D-flat3 on
beat one followed by three B-flat3 quarters. Whole-mix cost falls 0.285635 to
0.284812 and HIGH 41 to 40 at 85.57% pitch / 57.14% bass; accompaniment falls
0.258985 to 0.258550 and HIGH 38 to 37 at 83.18% pitch / 50% bass. Exact
comparison finds only four m177 pitch-node changes and keeps 2,595 events.
Native page-45 engraving, guided fingering, eighth=147 playback, normalized
semantic MXL export/reimport, WGSL/system reload, and the 1,704-region sampled
grand pass without faults; strong dual-reference coverage reaches 65 measures.
The bar remains `REVIEW_REQUIRED` for musician dynamics, articulation, pedal,
and final ear adjudication.
Measure 179 also differs from its copied source texture. Preserving the four
quarter attacks while replacing the B-flat octave with
F3-A-flat3-A-flat2-A-flat3 follows the shared locked window and separated
guitar transition. It outperforms passing D-flat-led and static-octave controls:
whole-mix cost falls 0.284812 to 0.283430 and HIGH 40 to 39 at 100% pitch /
62.5% bass; accompaniment falls 0.258550 to 0.255678 and HIGH 37 to 36 at
97.03% pitch / 87.5% bass. Exact comparison finds only four m179 pitch-node
changes and keeps 2,595 events. Native page-45 engraving, guided fingering,
eighth=147 playback, normalized semantic MXL export/reimport, and the sampled
grand pass without faults; strong dual-reference coverage reaches 66 measures.
The bar remains `REVIEW_REQUIRED` for musician dynamics, articulation, pedal,
and final ear adjudication.
Measure 183 needs chord shells because the two fixed evidence windows are
slightly offset and no coherent single-note line covers both. Its four-beat
lower voice becomes B-flat2, B-flat2+A-flat3, B-flat2+F3, D-flat3+F3: a
playable seventh, fifth, and minor-third progression assembled only from
independently supported tones. Whole-mix cost falls 0.283430 to 0.281225 and
HIGH 39 to 38 at 96.46% pitch / 78.57% bass; accompaniment falls 0.255678 to
0.254951 and HIGH 36 to 35 at 87.18% pitch / 71.43% bass. Exact comparison is
confined to m183 and adds three intentional chord tones, bringing the private
source to 2,598 events. Native page-46 engraving, guided fingering,
eighth=147 playback, normalized semantic MXL export/reimport, and the sampled
grand pass without faults; strong dual-reference coverage reaches 67 measures.
The bar remains `REVIEW_REQUIRED` for musician dynamics, articulation, pedal,
and final ear adjudication.
Measure 184 has a simpler common solution: D-flat3 followed by three E-flat3
quarters. The rhythm stays untouched and the exact full/accompaniment frame
intersection supports the pickup and repeated E-flat without added harmony.
Whole-mix cost falls 0.281225 to 0.280087 and HIGH 38 to 37 at 98.13% pitch /
62.5% bass; accompaniment falls 0.254951 to 0.252827 and HIGH 35 to 34 at
96.14% pitch / 56.25% bass. Exact comparison finds only four m184 pitch-node
changes and keeps 2,598 events. Native page-46 engraving, guided fingering,
eighth=147 playback, normalized semantic MXL export/reimport, and the sampled
grand pass without faults; strong dual-reference coverage reaches 68 measures.
The bar remains `REVIEW_REQUIRED` for musician dynamics, articulation, pedal,
and final ear adjudication.
The recording triage also distinguishes disagreement from absence of audible
evidence. Below the audit's existing 0.003 RMS boundary, authored accompaniment
is `MANUAL` with an explicit sustain/release ear-review reason instead of being
declared wrong by empty chroma; a structurally missing left hand is still
`HIGH`. A regression test fixes that ordering. The change affects only
full-mix m191-m193 and accompaniment m192 classifications—no timing, cost,
pitch, or score data changes. Accompaniment m191/m193 remain `HIGH`, every tail
bar remains `REVIEW_REQUIRED`, and the shared-HIGH intersection falls to 13
without manufacturing a silent-tail correction.
Measure 96's restored Db-Ab cadence now reaches 91.8% pitch-class and 70% bass
agreement; measure 37's restored Gb-add2 sonority reaches 90.1% pitch-class
agreement but still fails the automated bass check. Those bars and the
remaining voicing, rhythm, dynamics, articulation,
and pedal decisions must be reconstructed as a coherent two-hand piano
reduction before the recording-led accuracy gate can close.
Measure 94 is the next accepted full-voice correction. A reusable authoring
tool replaces only one named part/measure/staff/voice from explicit JSON,
requires exact meter duration, supports rests/chords/beams and key-aware
accidentals, removes the selected voice's forwards, preserves every unrelated
XML element, and records evidence metadata. The promoted candidate replaces
the unsupported A-flat fragment with recording-led D-flat/E-flat/F/B-flat
upper texture and B-flat-F-A-flat-B-flat lower motion. It passes both unchanged
gates: full-mix cost 0.284912 -> 0.281513 and HIGH 64 -> 63 (96.57% pitch,
66.67% bass), while vocal-free cost 0.268818 -> 0.266360 and HIGH 63 -> 62
(91.45% pitch, 71.43% bass). The current private MXL is structurally clean at
193 measures / 2,575 events; native playback, export/reimport, guided keys,
sampler telemetry, and live Flecs/WGSL reload all pass. This is a measured
improvement, not professional certification: dynamics, articulation, pedal,
fingering, and final musician ear review remain open.

Measure 55 is the next accepted lower-register correction. The supplied draft's
D-flat3/D-flat4 bass has no support in the aligned full mix, vocal-free
accompaniment, or six-stem review; the guitar stem repeatedly identifies
A-flat2/A-flat3 through the target window. A rhythm-preserving A-flat-octave
candidate changes only those two pitches and its provenance metadata. The
full-mix gate improves 0.281513 -> 0.281508 and HIGH 63 -> 62, with 91.25%
target pitch-class and 50% bass agreement. The vocal-free global cost remains
exactly 0.266360 while HIGH falls 62 -> 61, with 100% target pitch-class and
50% bass agreement. That cost-neutral result is accepted because global DTW is
pitch-class/onset based while the independently gated bass metric is
register-aware; candidates still may not regress the global cost and must lower
the HIGH queue. Native Metal playback at bar 55, the 1,704-region/641-preloaded
sampled grand, live Flecs/WGSL reload, GPU readback, and native
export/re-import all pass with zero sampler drops or overloads. The score
remains structurally clean at 193 measures, 2,575 note/rest events, and 1,794
pitched events. Measure 55 remains `REVIEW_REQUIRED` pending a musician's ear,
voicing, fingering, dynamics, articulation, and pedal confirmation.

Measure 61 is the next accepted lower-register correction. Both aligned audits
already had 100% target pitch-class agreement but 0% bass agreement for the
draft A-flat3/E-flat3 half notes. Time-resolved Basic Pitch events across the
separated guitar, other, and piano stems repeatedly identify F3 through both
halves of the bar; both aligned references independently rank F3 first in the
bass. The authorized page is retained only as secondary rhythm/engraving
evidence, not as the pitch authority. F3-D-flat3 and F3-C3 alternatives are
rejected by the unchanged local or global gates. The promoted sustained-F3
candidate changes only the two lower pitches plus provenance and preserves
both half-note durations. Global costs remain 0.281508 full mix / 0.266360
vocal-free while HIGH falls 62 -> 61 and 61 -> 60. Target agreement is 100%
pitch class in both references and 75% / 87.5% bass. Native Metal playback,
GPU readback, live Flecs/WGSL reload, sampler telemetry, and export/re-import
all pass; the latter retains 193 measures, 2,575 note/rest events, and 1,794
pitched events. Measure 61 remains `REVIEW_REQUIRED` pending musician voicing,
fingering, dynamics, articulation, pedal, and final ear confirmation.

Measure 120 is the next accepted bass-register correction. Its draft lower
voice alternates A-flat3/E-flat4 in four existing eighth-note attacks; both
aligned references report 100% overall pitch-class agreement but 0% bass
agreement. All three separated instrument stems identify F3, and the
time-resolved piano stem repeats it across the target window. Four
rhythm-preserving F3 attacks are the only tested ordering to pass both unchanged
gates; three F/D-flat orderings fail a target bass threshold or increase the
full-mix HIGH queue. The promoted candidate changes only those four lower
pitches plus provenance. Full-mix cost improves 0.281508 -> 0.281096 and HIGH
61 -> 60, with 100% pitch / 60% bass agreement. Vocal-free cost improves
0.266360 -> 0.266033 and HIGH 60 -> 59, with 100% pitch / 75% bass agreement.
Native Metal playback, GPU readback, live Flecs/WGSL reload, zero-fault sampled
grand telemetry, and export/re-import all pass with exact 193-measure / 2,575
note-rest / 1,794-pitched-event retention. Measure 120 remains
`REVIEW_REQUIRED` pending musician voicing, fingering, dynamics, articulation,
pedal, and final ear confirmation.

Measure 119 is the next accepted rhythm-preserving lower-register correction.
Its A-flat3/E-flat4 alternation has 0% bass agreement in both timelines. The
accepted full/accompaniment frame mappings plus separated guitar, piano, and
other stems support C3-D-flat3-F3-C3 on the four existing eighth-note slots;
both quarter rests and the beaming remain unchanged. Full-mix cost improves
0.281096 -> 0.281024 and HIGH 60 -> 59 with 100% pitch / 60% bass. Vocal-free
cost improves 0.266033 -> 0.265124 and HIGH 59 -> 58 with 100% pitch / 66.67%
bass. Parsed-tree comparison proves all non-target semantics unchanged. Native
Metal playback/readback at bar 119, phrase-aware finger state, live Flecs/WGSL
reload, the 1,704-region/641-preloaded sampled grand, and export/re-import all
pass with no sampler faults and exact 193-measure / 2,575-note-rest /
1,794-pitched-event retention. The bar remains `REVIEW_REQUIRED` for musician
voicing, fingering, dynamics, articulation, pedal, and final ear confirmation.

Measure 121 is the next accepted unambiguous lower-register correction. Its
four existing attacks carry B-flat/D-flat/G-flat/B-flat, while every mapped
bass frame in both accepted timelines is F3. Four F3 eighth notes retain the
original two-beam/two-rest rhythm. Both gates reach 100% pitch / 100% bass:
full-mix cost improves 0.281024 -> 0.280010 and HIGH 59 -> 58; vocal-free cost
improves 0.265124 -> 0.263877 and HIGH 58 -> 57. Non-target parsed semantics
are identical. Native Metal playback/readback, phrase finger state, live
Flecs/WGSL reload, the zero-fault sampled grand, and export/re-import all pass
with 193 measures, 2,575 note/rest events, and 1,794 pitched events. The bar
remains `REVIEW_REQUIRED` for musician articulation, dynamics, voicing, pedal,
and final ear confirmation.

Measure 118 is deliberately not edited. A rhythm-preserving
B-flat2-B-flat2-G-flat2-A-flat2 candidate follows the separated guitar/other
events and improves both global costs (0.281024 -> 0.280847 full and 0.265124
-> 0.263546 vocal-free). It passes the vocal-free gate at 100% pitch / 80%
bass, but the whole mix reaches 94.75% pitch / 40% bass and fails the unchanged
45% target. Substituting the detector-favored A-natural would lack independent
stem support and would turn the gate into metric gaming. Retain the authored
bar as `HIGH` / `REVIEW_REQUIRED` for an ear-and-piano decision.

The recording audit now reports `low_register_candidate_agreement` beside its
strict primary-bass agreement. This non-gating diagnostic considers the frame's
single bass estimate plus ranked pitches below C4, exposing a likely harmonic
or semitone mistake without promoting it to an authoritative fundamental.
Measure 43 demonstrates the distinction: the primary field gives 0%/25% for
the authored A-flat2/A-flat3, while the same frames provide 50%/75% low-register
A-flat support and all three separated stems repeatedly transcribe A-flat. The
score is deliberately unchanged; replacing it with detector-favored A-natural
would discard stronger independent evidence.

An earlier measure-114 pass rejected five lower-voice-only candidates: each
either improved one reference while worsening the other or missed a bass
threshold. That rejection remains useful evidence against a static bass edit,
but it was superseded by the later complete two-voice, time-resolved matrix
described above. The accepted B-flat/D-flat to C/B-flat transition clears both
locked references while preserving the authored rhythm; the bar is now
`MANUAL` but remains `REVIEW_REQUIRED` for musician adjudication.

Measure 171 is also deliberately not edited. Its authored A-flat3/F3 halves
produce 100% pitch-class but 0% bass agreement in both accepted timelines.
Time-resolved full-mix, vocal-free, and separated guitar/piano/other evidence
suggests B-flat/G-flat/A-flat motion, so seven register and rhythm variants are
audited. The strongest sparse line—B-flat2 quarter, G-flat2 half, A-flat2
quarter—turns the bar MANUAL with 100% pitch and 50%/87.5% bass and lowers both
HIGH queues by one. It nevertheless worsens the global costs from 0.281096 to
0.281143 and 0.266033 to 0.266088. The unchanged Pareto gates reject it: a
local detector fit is not enough to distinguish the intended musical bass
from stem fundamentals or onset/alignment ambiguity.

## 1. Product definition

Build a fast, local-first music-notation application as an engine-style Zig/Flecs program. The application owns its entire UI, layout, hit testing, animation, notation scene, and accessibility model. A browser is only one export host: its Wasm build presents the same GPU application on a WebGPU surface, while macOS, iOS/iPadOS, Windows, and Linux hosts provide equivalent native surfaces and device services.

The long-term reference is the workflow breadth of MuseScore, not a copy of its source, visual identity, or exact interface. A credible first release should be excellent at reading, practicing, annotating, and making common edits. Full professional engraving parity is a multi-year product, so features are deliberately staged.

### v1 promise

- Run the same application model as a native executable or a browser-delivered Wasm/WebGPU build.
- Install the browser export as a PWA where the host supports it.
- Create a score or import MusicXML/MXL and standard MIDI.
- Display common Western notation with accurate spacing and pagination.
- Play the score with a good piano sound, tempo control, looping, count-in, and metronome.
- Listen through MIDI or the microphone, follow the player through the score, identify confident pitch/rhythm mistakes, and suggest focused improvements after a take.
- Edit common notation with touch, mouse, keyboard, or a connected MIDI keyboard where Web MIDI is available.
- Draw, highlight, erase, lasso, and add text notes without changing the score.
- Save continuously in the browser, export a portable document, and recover after a crash or refresh.
- Use the same responsive GPU UI and Flecs systems across WebGPU, Metal, Vulkan, and D3D12 hosts. Phones are supported mainly for viewing and playback, not dense score editing.
- Optionally sign in to synchronize the library across browsers. Anonymous use remains fully functional but device-local.

### What “any score” means

No notation application can semantically understand every PDF or proprietary format. The product will provide explicit support levels:

| Input | Display | Playback | Semantic editing | v1 status |
| --- | --- | --- | --- | --- |
| MusicXML 4.0 (`.musicxml`, `.xml`, `.mxl`) | Yes | Yes | Yes, for supported elements | Required |
| Standard MIDI (`.mid`, `.midi`) | Generated notation | Yes | Yes, after quantization review | Required |
| Native package (`.score`) | Yes | Yes | Yes | Required |
| PDF | Original pages | No automatic playback | Ink/text annotations only | Required |
| Images | Original image | No automatic playback | Ink/text annotations only | Later |
| MuseScore/Sibelius/Finale native files | Via MusicXML export | Via MusicXML export | Via MusicXML export | Direct import is not v1 |
| Scanned sheet music | As PDF/image | No | Annotation only | Optical music recognition is a later research project |

Unknown MusicXML elements should be retained as opaque source fragments when safe, and the importer must report unsupported or approximated content. It must never silently claim a lossless round trip.

## 2. Copyrighted private acceptance fixtures

Copyrighted works used for private acceptance testing must never become bundled
catalog content. The repository and public deployment must not contain their
notation, lyrics, recordings, album artwork, or unlicensed sound-alike
arrangements.

Private development fixtures are handled in one of these lawful ways:

1. Import a MusicXML, MXL, MIDI, or PDF file the user obtained lawfully. The
   file stays local unless the user explicitly enables sync.
2. Keep a developer-owned licensed fixture under `local-content/`, ignored by
   Git and excluded from every build and public screenshot.
3. Bundle any work only after written distribution rights are recorded under
   `legal/content-licenses/`, including territory, term, arrangement, lyrics,
   and offline-cache rights.

Until option 3 is satisfied, use public-domain or appropriately licensed scores
for automated tests, screenshots, the hosted demo, and first-run content. Song
title/artist metadata may identify a user-imported document, but it is not a
substitute for rights to the musical work.

“Holocene” acceptance test, using a lawful user-supplied fixture:

- Import completes without losing the original file.
- Title and creator metadata can be corrected by the user.
- Every imported page can be viewed at readable zoom.
- Playback, seeking, tempo changes, measure looping, and the moving cursor remain synchronized.
- A lawful performance can be captured as microphone audio and/or MIDI, assessed with confidence, and replayed in sync.
- Ink and text annotations stay anchored after zoom, reflow, refresh, offline restart, and export/import.
- Unsupported notation is listed in an import report rather than silently discarded.

## 3. Technical decisions

### 3.1 Toolchain

- Pin Zig **0.16.0**, the latest official stable release on 2026-08-21, in CI and developer setup. Do not build releases from Zig `master`.
- Pin Flecs **4.1.6** at commit `fb55f3c25660425cfe1bc4cf5e6bff8b3f18a9b8` as the `vendor/flecs` Git submodule. Update it only in an isolated dependency change with native and Wasm regression tests.
- Compile browser modules for `wasm32-emscripten`; do not require WASI in the browser.
- Keep the visible application free of DOM UI, HTML components, CSS layout, React, Preact, and website frameworks. All product pixels and interactions are generated by the shared Zig UI and render systems.
- Use Emscripten only as the browser export linker and thin platform bridge. Its generated launcher is packaging infrastructure, not an application view.
- Define the renderer around a Zig-owned WebGPU-shaped facade. The browser host binds it to Emdawnwebgpu; native hosts bind the same contract to Dawn/Metal/Vulkan/D3D12 as appropriate.
- Run Zig tests natively for speed and run the same portable core tests against Wasm in browsers.

The installed Zig is 0.16.0. Xcode is not a browser build dependency; it is used
only by the existing macOS/iOS platform packaging and signing paths.

### 3.2 Portable core and thin hosts

```text
                    Zig + Flecs portable core
┌─────────────────────────────────────────────────────────────────────┐
│ score model  commands  engraving  score following  assessment      │
│ playback timeline  render extraction  undo  persistence schema     │
│ Flecs entities/components/systems/observers/custom events/pipeline  │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ narrow versioned facades
             ┌─────────────────┼──────────────────┐
             v                 v                  v
┌────────────────────┐ ┌─────────────────┐ ┌────────────────────────┐
│ Web host            │ │ iOS/iPad host   │ │ macOS native host      │
│ Wasm + WebGPU       │ │ Metal + Core*   │ │ Dawn + Metal           │
│ Web Audio/MIDI/mic  │ │ AVAudio/CoreMIDI│ │ CoreAudio/CoreMIDI     │
│ IndexedDB + PWA     │ │ app support     │ │ app support + panels   │
└─────────────────────┘ └─────────────────┘ └────────────────────────┘
```

The core imports no DOM, WebGPU, Web Audio, Apple, Win32, or POSIX APIs. Hosts implement explicit interfaces for graphics, audio I/O, MIDI, microphone capture, storage, networking, time, jobs, clipboard, accessibility, and lifecycle. The semantic score and durable file format must not contain browser or native platform types.

The browser export is split as follows:

- The main Wasm module owns the Flecs world, application loop, GPU UI tree, score, layout, score follower, assessment, and render extraction.
- The browser host owns only the WebGPU surface and permissioned device/service calls. It forwards normalized events into the same platform input queue used by native hosts.
- `audio_dsp.wasm` in an AudioWorklet owns the real-time sampler/mixer and low-latency microphone front end.
- A generated launcher and Service Worker package the game-style Wasm artifact; IndexedDB stores local documents and journals.
- No application view or control is implemented in HTML, CSS, Canvas 2D, WebGL, or a JavaScript UI framework.

### 3.3 Flecs is the runtime backbone

Use the vendored Flecs C API through Zig `@cImport`. Compile the amalgamated C source with Zig for native tests and `wasm32-freestanding`. Use `FLECS_CUSTOM_BUILD` and enable only `FLECS_SYSTEM`, `FLECS_PIPELINE`, and `FLECS_TIMER` in release builds; observers and custom events are core features. Debug tools may additionally enable `FLECS_META`, `FLECS_DOC`, and `FLECS_STATS`. Do not ship Flecs HTTP, REST, JSON, Script, Explorer, Alerts, or Metrics in the browser module.

Flecs owns runtime storage and flow:

- Score elements are entities with typed components and stable persisted IDs.
- Relationships express document/part/staff/measure/voice ownership and notation links.
- Edit requests, input samples, playback events, invalidations, sync changes, and UI intents are typed ECS events or transient entities.
- Ordered systems perform input ingest, command validation, mutation, score following, assessment, engraving, render extraction, audio scheduling, persistence, and UI snapshot publication.
- Observers invalidate derived data and enqueue work. They must not hide untracked semantic edits.
- A custom deterministic pipeline and explicit phase dependencies replace declaration-order assumptions.
- One Flecs world represents one open document/session. Multiple open documents use isolated worlds.
- Flecs entity IDs and table memory are runtime details; they are never serialized directly.

### 3.4 WebGPU-only web renderer

The browser build requires WebGPU. It has no Canvas 2D or WebGL rendering backend and no software renderer. The HTML canvas is used only as the `GPUCanvasContext` presentation surface. If `navigator.gpu`, a suitable adapter, or required limits are unavailable, show a polished unsupported-browser page with detected reasons and supported-browser guidance; do not partially enter the editor.

WebGPU is the right browser API here because browsers map it onto modern native graphics stacks such as Metal, Vulkan, and Direct3D. Direct Vulkan is not exposed to ordinary web pages. WebGPU provides render and compute pipelines, storage buffers, indirect drawing, and WGSL while preserving the browser security model.

Keep WebGPU behind a Zig-owned `GpuBackend`/render-hardware interface. The interface exists so future native hosts can implement Metal, Vulkan, or D3D12—not to select an older browser renderer. Render packets, resource descriptions, shader interfaces, coordinate systems, blend rules, and color management remain platform-neutral.

Required web capabilities:

- WebAssembly with streaming instantiation and a byte-buffer fallback for incorrect MIME configuration.
- WebGPU core in a secure context, with adapter/device-loss handling.
- Dedicated Worker, Web Audio/AudioWorklet, Pointer Events, IndexedDB, Service Worker, and web app manifest.
- `getUserMedia` only when the user starts microphone practice.

Optional WebGPU features such as timestamp queries and `shader-f16` create quality/performance tiers inside the WebGPU backend. They are not separate rendering fallbacks. `SharedArrayBuffer`, Wasm threads, Web MIDI, File System Access, and Background Sync remain optional platform enhancements.

### 3.5 Development hot reload and monolithic releases

Component schemas, stable document IDs, Flecs world ownership, render resources, and platform devices live in the host. Reloadable application modules publish a versioned descriptor containing systems, query terms, phases, event subscriptions, callbacks, migrations, and an optional module-local state serializer.

- Native development builds compile systems into watched dynamic libraries. A reload is prepared beside the live module, ABI-checked, and installed at a frame boundary. Changed queries recreate only their Flecs system entities; component data and unrelated systems remain live.
- Debug native builds also expose a user-only Unix-domain socket at
  `/tmp/score-dev-<uid>.sock` (overridable with `SCORE_DEV_SOCKET`).
`score-devctl` can inspect the live Flecs session, load a local score, control
transport/tempo/UI state, request a reload, and call the current dylib's
versioned development-command hook. New one-off Zig operations are written
in the hot module, rebuilt with `zig build systems`, and invoked as
`score-devctl plugin <command>` without restarting the world. The host copies
bounded note-snapshot edits back into Flecs at the same frame boundary. The
same control surface exposes `sampler state` telemetry and routes validated
`midi` commands to both the core/practice recorder and the live sfizz instance,
which makes channel, velocity, and pedal behavior testable without GUI input.
`sampler state` includes the four detail values confirmed on the audio thread;
`sampler detail studio|dry|RELEASE HAMMER PEDAL_NOISE RESONANCE` changes them
without replacing the document or restarting the process.
The server never unlinks a socket merely because bind failed: it first probes
the existing endpoint, returns `SocketInUse` for a live owner, and only removes
a stale path before retrying. This prevents a second app instance from silently
stealing hot-reload control from the watched native session.
- A failed compile, load, ABI check, or migration keeps the last working module active and reports the error through the GPU developer overlay.
- Browser development rebuilds the Wasm application and performs a live restart from a versioned serialized world snapshot. This avoids making Wasm dynamic linking a production dependency while retaining rapid stateful iteration.
- The generated glyph atlas is hashed into the hot-module descriptor. A changed
  UV table cannot load against a stale host texture: the ABI check rejects it,
  and the development watcher rebuilds/relaunches the native host atomically for
  atlas, ABI, renderer, shader, audio, and other host-resource changes.
- Native Debug builds poll the WGSL source directly, create candidate Dawn
  pipelines asynchronously inside captured validation scopes, and swap only
  after shader and pipeline-interface validation succeeds. Invalid WGSL and
  missing entry points retain the last-good pipeline, preserve the live Flecs
  world, show a GPU notice, and expose exact diagnostics through
  `score-devctl shader state`. Release builds retain only the embedded shader.
- GPU resources are addressed by stable logical handles and restored/rebound
  after renderer or shader reloads. iOS consumes the same static render packet;
  its Debug host polls a writable application-support Metal source, builds a
  candidate library/pipeline asynchronously, and installs it on the main render
  thread only after validation. A rejected edit keeps the last-good pipeline
  and the live Flecs state. Release bundles only the precompiled metallib.
- Release builds import the same module descriptors statically. The watcher,
  dynamic-library loader, control socket, developer overlay, and migration
  diagnostics are removed, and Zig links the application into one platform
  binary (or one main Wasm module plus required browser packaging files).
- Reloadable callbacks may not retain Flecs table pointers, iterator pointers, Wasm linear-memory slices, or platform handles beyond the call. Long-lived state must be a registered component or a versioned serialized module block.

### 3.6 Production multi-sampled instrument engine

The former oscillator is only an emergency startup diagnostic. Normal browser
and iOS playback uses the shared sampled-piano engine and licensed compact
Salamander bank; native uses the complete sfizz pack. The long-term audio path
remains a general instrument engine, with the concert grand as its first
reference-quality library rather than a piano-only special case.

- Normalize imported SFZ, SF2, and open multisample libraries into a validated
  internal manifest with lossless assets, content hashes, explicit licenses,
  missing-file diagnostics, and optional downloadable packs.
- Support key, velocity, select, round-robin, and articulation zones with
  crossfades; per-zone root/tuning/gain/pan; note/release/FX chains; envelopes,
  filters, LFOs, and a polyphonic modulation matrix. The optional GPU editor
  borrows Bitwig's clarity—search, tagging, visible zone maps, waveform/loop
  editing, and live voice/streaming meters—without copying its UI or turning
  the practice surface into a DAW.
- Stream or preload samples without allocation, locks, disk access, or decoding
  on the real-time callback. Publish bounded lock-free commands from the Flecs
  world and expose underrun, memory, I/O, voice, and latency telemetry.
- For the concert grand, require dense velocity/timbre interpolation,
  multi-mic perspectives, release/mechanical/pedal samples, half-pedal,
  repedaling, sostenuto, una corda, sympathetic/string/damper resonance, and
  high-quality convolution/spatial output. Preserve CC64/66/67 and high-
  resolution MIDI/per-note expression in recording and replay.
- Use one Zig musical/DSP implementation on native, Wasm AudioWorklet, and iOS;
  platform code owns only device/session, decoding/I/O facades, and callback
  delivery. Quality gates include deterministic offline renders, spectral
  regression, pedal-state and no-dropout stress tests, latency calibration, and
  blind listening on monitors/headphones.

## 4. Repository layout

```text
/
├── IMPLEMENTATION.md
├── README.md
├── LICENSE
├── build.zig
├── build.zig.zon
├── src/
│   ├── core/
│   │   ├── ecs/               # Flecs world, components, relationships, phases
│   │   ├── score/             # semantic score components and stable IDs
│   │   ├── command/           # validated edits, transactions, undo/redo
│   │   ├── engraving/         # spacing, systems, pages, render extraction
│   │   ├── playback/          # repeats, tempo map, event timeline
│   │   ├── practice/          # score follower, assessment, recommendations
│   │   ├── annotation/        # anchored vector strokes and text notes
│   │   ├── import/            # MusicXML, MXL/ZIP, MIDI, native format
│   │   └── export/            # MusicXML, MIDI, PDF draw model, native format
│   ├── platform/
│   │   ├── gpu.zig            # backend-neutral graphics facade
│   │   ├── audio_io.zig       # output/input device facade
│   │   ├── storage.zig        # transactional blob/document facade
│   │   ├── network.zig        # sync transport facade
│   │   ├── time_jobs.zig      # monotonic clock and job facade
│   │   └── accessibility.zig  # semantic accessibility snapshot
│   ├── render/
│   │   ├── packet.zig         # backend-neutral resources and draw packets
│   │   ├── graph.zig          # passes, dependencies, transient resources
│   │   ├── glyph.zig          # SMuFL/text atlas and shaping data
│   │   └── shaders/           # canonical shader interfaces and tests
│   ├── wasm/
│   │   ├── score_exports.zig  # coarse-grained host ABI
│   │   └── audio_exports.zig  # real-time DSP ABI
│   ├── audio/                 # sampler, voices, mixer, effects, metronome
│   ├── protocol/              # binary message and native-file schemas
│   └── tools/                 # fixture inspector and format migration tools
├── web/
│   ├── index.html
│   ├── public/
│   │   ├── manifest.webmanifest
│   │   ├── icons/
│   │   ├── fonts/             # Bravura + required OFL notices
│   │   └── samples/           # only explicitly redistributable audio assets
│   └── src/
│       ├── app/               # routes, state, error boundaries
│       ├── components/        # accessible controls and dialogs
│       ├── editor/            # WebGPU surface, gestures, editing tools
│       ├── gpu/               # WebGPU backend, WGSL, resource cache
│       ├── audio/             # AudioContext/Worklet host and transport
│       ├── input/             # MIDI/microphone adapters and permissions
│       ├── storage/           # IndexedDB, migrations, recovery journal
│       ├── sync/              # optional authenticated sync client
│       ├── worker/            # score worker and typed Wasm bridge
│       ├── styles/            # tokens, layout, themes, print
│       └── sw.ts              # service worker
├── server/                    # required for cross-device sync, not local use
│   ├── src/                   # native Zig HTTP/WebSocket service
│   ├── migrations/            # PostgreSQL schema
│   └── deploy/
├── tests/
│   ├── fixtures/
│   │   ├── public-domain/
│   │   ├── generated/
│   │   └── licensed/          # ignored; never deployed
│   ├── golden/                # approved rendering snapshots
│   ├── browser/
│   └── fuzz/
├── legal/
│   ├── third-party-notices/
│   └── content-licenses/
├── vendor/
│   └── flecs/                 # Git submodule pinned to v4.1.6
└── .github/workflows/
```

## 5. Core ABI and platform facades

Avoid chatty calls and JavaScript object mirroring. The core exposes a small C-compatible ABI over Wasm linear memory:

```text
score_api_version() -> u32
score_init(config_ptr, config_len) -> status
score_dispatch(request_ptr, request_len) -> response_handle
score_response_ptr(handle) -> ptr
score_response_len(handle) -> len
score_response_release(handle)
score_alloc(len, alignment) -> ptr
score_free(ptr, len, alignment)
```

`score_dispatch` accepts versioned binary commands such as `OpenDocument`, `ApplyEdit`, `LayoutViewport`, `HitTest`, `BuildPlaybackRange`, `BeginPracticeTake`, `IngestInputBatch`, `FinalizeTake`, and `SerializeSnapshot`. Responses use fixed-width headers followed by packed arrays and UTF-8 slices.

Rules:

- Every request and response includes protocol version, opcode, request ID, byte length, and checksum for stored data.
- Pass a compact render packet per dirty region/frame, not one call per entity or glyph.
- JavaScript copies or transfers a response before releasing its handle.
- The worker owns the score-core Wasm instance and all core handles.
- Browser I/O is injected through messages; Zig does not receive ambient browser capabilities.
- Debug builds validate bounds, generations, UTF-8, command invariants, and leaked handles.
- Release builds retain input limits and format validation.

The portable core depends on interfaces rather than a web host:

```text
GpuBackend       create resource/pipeline, upload, encode pass, submit, present
AudioBackend     output clock, event queue, input frames, device/interruption state
InputBackend     pointer, keyboard, MIDI, microphone capability and permission state
StorageBackend   transactional blobs, journals, quotas, file import/export
NetworkBackend   authenticated request, stream, cancellation, connectivity
ClockBackend     monotonic nanoseconds and wall-clock metadata
JobBackend       submit/cancel bounded work and publish completion
A11yBackend      publish a semantic focus tree and receive accessible actions
```

Interfaces use opaque generational handles, plain value descriptors, byte slices, and explicit ownership. The Wasm host implements them through messages and JavaScript browser APIs. Future native hosts implement the same semantics without carrying TypeScript or DOM concepts into the core.

## 6. Core model and edit system

### 6.1 IDs and ownership

Use Flecs entities as runtime generational handles. Every durable entity also has a stable `PersistentId` independent of its Flecs ID, table, archetype, or load order. A document owns parts; parts own staves; measures own voices and events through Flecs relationships. Cross-references such as ties, slurs, tuplets, lyrics, takes, and annotations use persistent IDs in serialized data and resolved entity references at runtime.

Core entities:

- `Document`: metadata, style, parts, tempo map, annotations, imported-source report.
- `Part` and `Staff`: instrument, transposition, clefs, staff type, mixer route.
- `Measure`: meter, barline, voices, local layout overrides.
- `Event`: note/chord, rest, direction, harmony, figured bass, text, layout break.
- `Spanner`: tie, slur, hairpin, ottava, pedal, volta, trill line.
- `AnnotationLayer`: ink strokes, highlights, shapes, text notes, visibility.
- `PracticeSession` and `Take`: source configuration, calibration, score range, input tracks, result summary.
- `InputEvent`: timestamped MIDI, acoustic feature, transport, and device events; transient and pooled.
- `RenderItem`: extracted immutable GPU-facing data, never the source of score truth.

Represent musical positions exactly as reduced rational values. Convert them to audio sample time only when compiling a playback timeline. Never store score time as floating point.

### 6.2 Commands

All mutations are validated commands:

- `InsertNote`, `ReplaceDuration`, `DeleteSelection`
- `SetPitch`, `SetAccidental`, `ToggleTie`, `SetArticulation`
- `InsertMeasure`, `SetMeter`, `SetKey`, `SetClef`
- `SetTempo`, `SetDynamic`, `SetText`, `SetInstrument`
- `AddStroke`, `EraseStrokeRange`, `MoveAnnotation`, `SetLayerVisibility`

Commands enter the Flecs world as transient entities. `ValidateCommands` converts valid requests into a transaction; `ApplyCommands` mutates semantic components in a deferred Flecs stage, records inverse operations, identifies affected semantic ranges, and increments the document revision only after success. Layout, playback, persistence, sync, and UI snapshots consume the same `ChangeSet` event. This prevents competing notions of what changed.

The initial deterministic pipeline is:

```text
PlatformInput
  -> CommandValidate
  -> CommandApply
  -> ScoreFollow
  -> PerformanceAssess
  -> DerivedInvalidation
  -> Engrave
  -> RenderExtract
  -> AudioSchedule
  -> PersistJournal
  -> PublishSnapshot
  -> CleanupTransient
```

Systems with no work should not run merely because a frame elapsed. Event tags and queries activate document work; fixed-rate progression is reserved for practice/playback simulation. Audio time is authoritative during playback and recording, never render-frame time.

### 6.3 Incremental engraving

The layout dependency chain is:

```text
changed event
  -> voice collision and accidental pass
  -> measure width and vertical extents
  -> containing system break
  -> affected page range
  -> dirty GPU regions + hit-test index
```

Do not repaginate the full document for a pitch change that does not alter width. Cache measure layout by semantic hash + style hash + scale class. Virtualize pages and retain only visible pages plus a small prefetch window.

Initial engraving support:

- Pitched and unpitched notes, chords, rests, dots, beams, stems, flags.
- Treble, bass, alto, tenor, percussion, and octave clefs.
- Key and time signatures, accidentals, transposing instruments.
- Multiple voices, tuplets, grace notes, cross-staff notation in a later v1 iteration.
- Ties, slurs, dynamics, articulations, ornaments, hairpins, pedal.
- Lyrics, chord symbols, rehearsal marks, tempo text, measure numbers.
- Repeats, endings, D.C./D.S./Coda/Fine for layout and playback.
- Page/system breaks and a small, documented engraving-style set.

Use SMuFL mappings and metadata. Bundle the Bravura reference font only with its SIL Open Font License notice. Keep music glyph selection data-driven so other SMuFL fonts can be added later.

## 7. Rendering and interaction

### 7.1 Page renderer

- The Zig/Flecs core extracts backend-neutral GPU packets: instances, paths, glyphs, clips, bounds, materials, resource deltas, and pass intents.
- The WebGPU backend maintains immutable static buffers for unchanged score regions and dynamic ring buffers for cursors, ink, particles, and practice feedback.
- Use a render graph with explicit score-paper, notation, annotation, practice-feedback, UI-overlay, and final-composite passes.
- Partition long pages into GPU-resident regions and cull invisible systems before encoding draws.
- Cache resources by semantic hash, style hash, font revision, zoom bucket, and device scale.
- Use indirect/instanced draws where they reduce CPU encoding cost; keep a simpler WebGPU path for devices lacking optional features.
- Cancel obsolete uploads and render extraction after edits or rapid zoom changes.
- Keep staff lines aligned to physical pixels where possible and preserve print geometry independently from visual effects.
- Render hover, selection, entry preview, playback cursor, loop range, and in-progress strokes in WebGPU layers over immutable notation.
- During pinch zoom, transform existing GPU geometry immediately, then replace it with the newly extracted zoom bucket after the gesture settles.
- Provide a DOM accessibility mirror for the focused system/measure rather than exposing thousands of GPU draw objects.

### 7.2 Glyphs, curves, and shaders

- Generate a multi-channel signed-distance-field atlas for Bravura and the supported score-text fonts as a reproducible build asset.
- Shape score text in the portable core and emit glyph IDs/positions; DOM text is only for application chrome and accessibility.
- Render noteheads, clefs, accidentals, text, and other font glyphs with an MSDF fragment shader for sharp scaling.
- Render staff lines, stems, beams, barlines, selection boxes, and simple marks as instanced analytic shapes.
- Tessellate slurs, ties, hairpins, and arbitrary paths in Zig first; evaluate a compute-shader tessellator only after profiling and golden-image validation.
- Use premultiplied alpha, linear-light composition where appropriate, and explicit sRGB conversion.
- Compile WGSL pipelines asynchronously at startup, cache them, validate shader interfaces in CI, and recover all resources after device loss.
- Keep all score geometry deterministic. Time-based shaders may affect highlight, feedback, paper light, or particles but never the printed placement of notation.

GPU compute is reserved for work that is naturally parallel and measurable:

- visible-item culling and draw compaction for very large scores;
- pen-stroke resampling/tessellation after the immediate path is visible;
- batched constant-Q/spectral analysis and post-take spectrograms;
- practice heatmap reduction and particle simulation;
- optional page-texture generation for thumbnails and export previews.

Visual effects must serve state: a soft timing pulse at the playhead, brief pitch-correct sparks, restrained amber/red mistake markers, loop-range atmosphere, and a subtle paper/ink material. No bloom, animated grain, or particles may reduce staff/ledger-line contrast. Reduced-motion mode disables particles and continuous pulses while preserving semantic color/shape cues.

### 7.3 Hit testing

The worker builds a per-page spatial index over semantic bounds. The host sends one coarse pointer query; Zig returns ordered candidates with hit class and selection priority. Enlarge targets for touch without changing engraving. Consecutive drag updates use a captured target and do not re-run global hit testing.

### 7.4 Annotation input

- Capture coalesced Pointer Events when available.
- Store points in score coordinates with time, normalized pressure, tilt, and tool settings.
- Render raw points immediately through a small dynamic WebGPU vertex ring, then simplify and smooth the stroke in the core.
- Anchor page ink to a page revision and musical ink to a staff/measure plus local coordinates.
- Provide pen, highlighter, eraser, lasso, color, width, undo, and layer controls.
- Add a “pen draws, finger pans” setting and an explicit “draw with touch” fallback.
- Treat browser palm rejection as device-dependent; do not promise native PencilKit behavior.

## 8. Audio and practice

### 8.1 Playback pipeline

The score core expands repeats and navigation marks into a deterministic performance timeline. It resolves tempo, swing, grace timing, ties, ornaments, dynamics, articulation lengths, program changes, sustain, and mixer automation before sending bounded event batches to the audio host.

The host maintains a rolling schedule window against `AudioContext.currentTime`. A tiny Zig DSP module in an AudioWorklet owns active voices and the mixer. The audio callback must have:

- no allocation or deallocation;
- no locks or waiting;
- no XML/JSON decoding;
- no DOM or network work;
- bounded voice stealing;
- a monotonic event queue;
- underrun and late-event counters readable outside the callback.

Audio must start only after a user gesture, as required by browser autoplay policies. The transport should explain this with one clear **Enable sound** action instead of failing silently.

### 8.2 Piano sound

The first instrument is a compact multi-sampled piano. Before bundling samples, record the exact redistribution, modification, offline-cache, and commercial-use rights. Keep compressed download size and decoded memory within the performance budgets below. If an acceptable sample license is not yet secured, provide a clearly labeled basic synthesized piano and user SoundFont import; never copy samples from another notation app.

General MIDI instruments, per-part effects, and third-party sound libraries come after piano playback is stable.

### 8.3 Listening inputs and score following

Support two first-class input sources behind `InputBackend`:

1. **MIDI** is the highest-confidence path. Capture note on/off, velocity, channel, sustain/soft/sostenuto pedals, aftertouch, pitch bend, device timestamp, and connection changes where available.
2. **Microphone** works in supported secure-context browsers after the user grants capture permission. Request a mono stream with echo cancellation, noise suppression, and automatic gain control disabled when the browser honors those constraints. Keep the stream local and stop its track immediately when practice ends.

Both sources can run together. All input is mapped once onto the `AudioContext`/monotonic timeline using a calibration offset. A setup flow measures device latency, background noise, tuning reference, and piano range; it recommends headphones when app playback would leak into the microphone.

Do not attempt blind full-song transcription in the live path. The expected score provides a narrow pitch/time hypothesis window. An online Viterbi/beam-search follower aligns observations to score states while allowing repeats, pauses, restarts, skipped notes, and tempo drift.

For offline authoring, `score-workbench audio-evidence` accepts a lawful local PCM WAV and
emits a versioned JSON evidence ledger: onset envelope, tempo estimate, bass
candidate, pitch candidates, normalized chroma, and optional MusicXML/MXL
alignment. Its deterministic Goertzel-based implementation is deliberately a
review aid, not a claim of professional automatic transcription. A later
source-separation/learned transcription stage must preserve confidence and feed
the same manual correction/audit workflow. Streaming-site ripping is outside
the content pipeline; user-authorized private reference captures and local
exports remain ignored and must never be bundled or redistributed.

For native development on macOS, `scripts/capture-browser-reference.sh`
provides a reusable user-authorized loopback workflow for browser or app
playback. It discovers the current AVFoundation index for `BlackHole 16ch`,
temporarily selects that device as the macOS output by default, or accepts a
separate `--output-device` for an already configured aggregate/multi-output
route, captures stereo PCM24 WAV,
restores the previous output from an exit/signal trap, and invokes
`score-workbench audio-evidence` with an optional MusicXML/MXL comparison. The capture
command allows an application-settle interval, rejects silent captures,
refuses to overwrite evidence, and keeps acquisition separate from analysis so
the same workflow works for any song or local player.

Repository automation in `scripts/` is limited to thin platform build,
packaging, development, and authorized capture wrappers. MusicXML/MXL
inspection, transformation, audio alignment, and candidate gates are
subcommands of the tested Zig `score-workbench`; sampler gates live in the
single Zig `sampler_workbench`, and live native control in `dev_control`.
Licensed/private sources, generated score candidates, capture WAVs, analysis
ledgers, rendered output, scratch files, and Python bytecode live only in
ignored `local-content/`, `captures/`, `output/`, or `tmp/` paths. The policy is
recorded in `scripts/README.md`; genuinely one-off probes are deleted after
their conclusion is documented instead of accumulating as repository tools.

The 2026-08-23 SoundCloud redo also demonstrates why container duration and a
visible song title are not acceptance evidence. A long routed take was rejected
after content fingerprinting and small-model ASR disagreed with the accepted
recording. A separately visible 4:20 seek captured the actual late refrain and
overlapped the accepted 3:05 take at 0.842153 chroma similarity. Replacing the
accepted tail with it lowered global score-alignment cost from 0.280010 to
0.276901, but raised the HIGH queue from 58 to 62 and timing-anchor escapes from
2 to 3, so it remains independent review evidence and authors no notes.

After the user resumed playback, a further retry was verified as Holocene by
small-model ASR: the opening `part of me`/`laying waste` phrases recur after a
browser restart. BlackHole nevertheless receives active audio only through
74.65 seconds and then records silence. Four overlapping chunk attempts and two
pause/reload route probes are exactly -91 dBFS because Chrome retains the
speaker stream across later default-device changes. All are explicitly
excluded. The already accepted split timeline and the independently valid 4:20
tail remain the musical evidence; no score edit is promoted merely because a
new WAV exists.

MusicXML lyric text is modeled independently from notes. A named vocal part or
cue note is tagged as a vocal guide: it may render as an optional singer cue,
but it is excluded from instrument playback, keyboard fingering, and piano
assessment. This lets one document support piano-only practice, piano plus
lyrics, and a singer guide without doubling the sung melody into the reduction.

Microphone analysis pipeline:

```text
MediaStream
  -> AudioWorklet: DC removal, level, onset envelope, bounded PCM batches
  -> WebGPU compute: FFT/CQT, harmonic salience, multi-pitch activation
  -> Zig score follower: expected-note alignment and confidence
  -> Flecs assessment events + WebGPU feedback
```

The AudioWorklet cannot use WebGPU and must remain real-time safe. GPU analysis is batched outside the audio callback with a strict compute budget so it cannot starve rendering. A cheap CPU onset path gives immediate timing feedback while the richer polyphonic result arrives later. MIDI bypasses acoustic inference.

Assessment categories:

- correct, wrong, missed, or extra pitch;
- early/late onset and timing distribution;
- too short/long duration and articulation mismatch;
- unstable pulse, rushing/dragging, and tempo recovery;
- MIDI dynamics/velocity balance and pedal timing;
- microphone dynamics only when calibrated and confidence is sufficient.

Never present a low-confidence acoustic guess as a definite mistake. Store confidence and input source with every assessment. Chords under sustain, reverberant rooms, app-speaker leakage, and polyphonic overtones require a visible “uncertain” state.

### 8.4 Recording and take replay

Every practice run creates a `Take` with one shared monotonic timebase and any available tracks:

- raw timestamped MIDI events, including controllers and pedals;
- microphone audio in the browser-supported recorded MIME/container;
- optional app accompaniment/metronome stem;
- optional mixed master stem;
- transport actions, loop boundaries, calibration/latency values;
- score-position trace and assessment events;
- device/sample-rate/codec metadata required for synchronized replay.

The web host sends the same microphone `MediaStream` to the analysis graph and to `MediaRecorder`. MIDI events are journaled immediately. A `MediaStreamAudioDestinationNode` can capture the app accompaniment or an explicit mic+app mix without screen recording. Start/stop is transactional: if one track fails, preserve the others and report exactly what was recorded.

Replaying a take offers:

- **Real audio**: the recorded microphone or mixed master.
- **MIDI performance**: the original MIDI events through the sampler, preserving velocity and pedal.
- **Together**: aligned audio and MIDI with a user-adjustable correction offset.
- **Compare**: A/B two takes or place the reference performance against the user take.

Export audio in its original lossless/encoded track plus a widely playable derived file when available. Export MIDI as a Type-1 Standard MIDI File from the raw monotonic take timebase, preserving performance timing, channel data, and controller automation without notation quantization. Portable `.score` v14 stores the captured take tempo so the same take exports deterministically after recovery. Recording audio is opt-in for sync because it is large and sensitive; MIDI/assessment-only sync is the default. Show duration/size/quota before long recordings and write chunks incrementally so a refresh does not lose the whole take.

### 8.5 Practice features and coaching

- Tempo slider plus tap tempo.
- Count-in and metronome with configurable subdivision/accent.
- Loop measures or a selected range.
- Solo, mute, and per-part level.
- Follow cursor and performance mode with large page-turn targets.
- MIDI and microphone source selector with visible confidence/latency state.
- Record, stop, replay-as-audio, replay-as-MIDI, and compare-takes controls.
- Hands-separate practice, adaptive tempo, Bluetooth pedals, and focused measure drills.
- Post-take measure heatmap, pitch/timing/pedal breakdown, tempo trace, and uncertainty markers.
- Actionable recommendations such as “repeat measures 18–21 at 70%,” “practice left hand alone,” or “count eighth-note subdivisions”; every suggestion links to a configured drill.

Web MIDI is an enhancement because browser support varies. Microphone, manual note entry, and the on-screen piano remain available when MIDI is absent. A denied microphone permission must not block viewing, editing, playback, or MIDI practice.

## 9. Storage, files, and synchronization

### 9.1 Native `.score` package

Use a ZIP container with safe, versioned entries:

```text
manifest.json             # format version, UUID, revisions, hashes
score.bin                 # canonical semantic model
annotations.bin           # vector annotations and anchors
takes/index.bin           # take metadata, alignment, assessment summaries
takes/<id>/performance.mid# raw/derived MIDI performance when present
takes/<id>/events.bin     # score trace, transport, assessment, calibration
takes/<id>/audio.*        # original recorded audio track(s), when present
source/original.musicxml  # optional retained import source
source/original.pdf       # optional retained source, size permitting
preview.webp              # disposable library thumbnail
assets/*                  # explicitly referenced document assets
```

All binary schemas are little-endian, length-delimited, checksummed, and migration-tested. Caches and previews are disposable. Reject absolute paths, `..`, symlinks, duplicate normalized paths, decompression bombs, oversized entries, and impossible collection counts before allocation.

### 9.2 Local-first persistence

IndexedDB stores:

- library metadata and thumbnails;
- immutable document snapshots;
- an append-only operation journal since the last snapshot;
- import source blobs;
- chunked in-progress and completed take tracks, with crash-recovery state;
- audio preferences and small cached assets;
- schema and migration version.

Write a journal record before acknowledging an edit or MIDI batch. Write recording chunks as they arrive and atomically finalize the take index, so a crash loses at most the current chunk. Create score snapshots in the worker and prune the journal only after the new snapshot commits. Keep the previous valid snapshot for recovery. Request persistent storage when appropriate, show document/recording/cache usage separately, and allow complete export/deletion.

### 9.3 Cross-device sync

Anonymous mode is local to the current browser. To make the same library available “anywhere,” add optional sign-in and sync before public v1:

- Native Zig HTTPS service deployed as a small container.
- Managed OpenID Connect for authentication; the server validates short-lived tokens and stores no passwords.
- PostgreSQL for users, document heads, revisions, and device cursors.
- S3-compatible object storage for encrypted-at-rest snapshots and explicitly opted-in recordings/source blobs.
- Local edits sync as idempotent operation batches identified by document/device/sequence.
- Optimistic revision checks prevent silent overwrites.
- If two devices edit the same semantic region concurrently, preserve both revisions and ask the user which to keep; do not invent an unsafe musical merge.
- Sync MIDI/assessment take data by default for signed-in users; require an explicit per-library choice before uploading microphone audio.
- A WebSocket may reduce latency while the app is open, but ordinary HTTPS pull/push remains the correctness path.

Real-time multi-user collaboration and a music-aware CRDT are not v1 requirements.

## 10. UI specification

### 10.1 Visual principles

- The score is the primary object; controls recede when not needed.
- Use a warm paper/ink material, deep neutral application chrome, and a focused cyan accent; practice feedback adds green, amber, red, and violet only with redundant shape/text meaning.
- Keep tool state visible and reversible. Every destructive command supports undo.
- Minimum interactive target: 44 × 44 CSS pixels on touch layouts.
- Use system text fonts and Bravura for notation; do not imitate MuseScore branding.
- Support light, dark chrome with light paper, high contrast, reduced motion, 200% browser zoom, keyboard-only use, and screen readers.
- Prefer short labels with tooltips and shortcuts over unexplained icon-only controls.
- Let the editor feel like a precise creative tool and practice mode feel like a restrained rhythm game. Do not gamify score editing, saving, privacy, or error messages.

The visual-research pass surveyed notation/readers such as StaffPad and forScore, interactive score practice such as Soundslice, and feedback-first practice such as Melodics. The reusable patterns are: nearly full-screen paper; compact floating annotation tools; a stable bottom transport; current-note/measure emphasis; an optional keyboard/instrument strip; minimal live scoring; and a richer post-take review. Do not copy layouts or visual assets. Build these principles into project-owned components and shaders.

### 10.2 Library screen

- Header: product name, search, import, new score, account/sync state.
- Continue card for the most recently opened document.
- Responsive score grid with title, composer, parts, modified time, sync/offline badge.
- First-run cards: **Import score**, **Open recent**, **Try a public-domain
  example**, **Create an empty score**. Do not name a private acceptance fixture
  in product onboarding.
- Import progress, format warnings, and recovery actions appear inline; raw errors remain in a copyable details panel.

### 10.3 Editor — wide layout

```text
┌────────────────────────────────────────────────────────────────────┐
│ Back  Title / saved state       Undo Redo    Share Export  Help   │
├──────┬───────────────────────────────────────────────┬─────────────┤
│ tool │                                               │ Inspector   │
│ rail │          centered virtualized score           │ / palette   │
│      │                                               │             │
├──────┴───────────────────────────────────────────────┴─────────────┤
│ Rewind  Play  Record  Time/Measure  Tempo  Metronome  Loop  Mixer │
└────────────────────────────────────────────────────────────────────┘
```

- Collapsible left tool rail: select, note input, notation, text, annotate.
- Optional right inspector: context-sensitive properties, not a permanent form wall.
- Bottom transport remains reachable and does not cover the score.
- Record opens a compact source/stem chooser on first use and then becomes a one-action control with an unmistakable active state and elapsed time.
- Space toggles playback; arrows navigate; `N` enters note mode; number keys set duration; common shortcuts follow platform conventions.

### 10.4 Editor — iPad/tablet layout

- Full-width score with compact top bar and bottom transport.
- Tools open as a bottom sheet or floating palette near the selection.
- Pencil/pen draws or enters notes according to the active tool; one-finger drag pans; two-finger gesture zooms.
- Landscape may show the inspector; portrait uses sheets.
- Performance mode hides editing chrome, prevents accidental editing, keeps the screen awake when permitted, and exposes large previous/next page zones.
- Respect safe-area insets, split view, browser toolbar changes, and virtual keyboard resizing.

### 10.5 Practice mode

Practice is a dedicated mode, not a pile of badges on the editor:

```text
┌────────────────────────────────────────────────────────────────────┐
│ Exit     Holocene · mm. 18–25        MIDI + Mic  ● REC  01:42     │
├────────────────────────────────────────────────────────────────────┤
│         score with calm playhead and note-level feedback           │
│                                                                    │
│     [ current phrase / timing lane only while feedback is useful ] │
├────────────────────────────────────────────────────────────────────┤
│ optional 88-key strip: expected / pressed / uncertain notes        │
├────────────────────────────────────────────────────────────────────┤
│ Stop   76 BPM   Count-in   Loop   Left hand   Input level/conf.    │
└────────────────────────────────────────────────────────────────────┘
```

- Live feedback is peripheral and short-lived: current target, early/late direction, confident wrong/missed note, input level, and lost-position recovery.
- Never cover the notes the player is currently reading with scores, streaks, particles, or dialogs.
- Correct playing may produce a subtle shader pulse/particle accent; errors use a brief marker that remains reviewable after the phrase.
- “Wait mode” may pause at a checkpoint for the expected notes; adaptive tempo may increase only after a user-visible rule is met.
- Stopping reveals a results transition into a measure heatmap, timing distribution, pitch/pedal details, waveform/MIDI lanes, replay controls, and two or three prioritized drills.
- A numeric score is secondary to musical diagnostics. Do not punish low-confidence microphone inference or optimize engagement through manipulative streak loss.

### 10.6 Feedback states

Every long operation has progress and cancellation. Use four save states only: `Saving locally`, `Saved on this device`, `Syncing`, `Synced`. Recording adds explicit `Armed`, `Recording`, `Finalizing`, and `Recovered partial take` states. Offline is a normal state, not an error. On failure, preserve the user’s work and offer export before retrying destructive recovery.

## 11. Security and privacy

- Serve production only over HTTPS with a restrictive Content Security Policy.
- Keep Wasm imports minimal and audit them as capabilities.
- Request microphone access only from an explicit **Use microphone** action, show an in-app capture indicator, name the active input, and stop all tracks when the take ends or the user disables listening.
- Disable XML DTDs and external entities. Apply depth, token, string, measure, note, and total-byte limits.
- Validate ZIP central directory and each decompressed entry before use.
- Sanitize displayed metadata and never inject score text as HTML.
- Store authentication tokens outside exported documents and avoid long-lived browser tokens.
- Use CSRF protection, rate limits, authorization checks per document, audit logs for account actions, and signed upload URLs.
- Do not upload anonymous documents, imported scores, microphone audio, or pen/input telemetry. Signed-in microphone-audio sync is separately opt-in and revocable.
- Run pitch/onset inference locally. Raw audio is never required for analytics or coaching and is retained only when the user enabled recording.
- Make analytics opt-in during development; collect performance aggregates without score titles or contents.
- Provide export-all and delete-account/data flows before enabling accounts.

## 12. Performance budgets

Measure on a recent desktop, a current base iPad, and the oldest supported iPad. Record device/browser/build with every result.

| Metric | Release budget |
| --- | --- |
| Cached app-shell interactive | <= 1.0 s at p75 on target devices |
| Initial compressed JS + Wasm, excluding fonts/samples | <= 1.5 MB Brotli goal; <= 2.5 MB hard gate |
| First visible page after choosing a normal MusicXML file | <= 750 ms p95 |
| 100-page score open to first page | <= 1.5 s p95; remaining parse/layout progressive |
| Pan/zoom compositor | 60 fps p95; 120 fps where supported is a stretch goal |
| WebGPU frame CPU encode time | <= 2 ms p95 in steady-state reading/practice |
| WebGPU score pass | <= 4 ms GPU p95 on target iPad; full frame <= 8 ms at 120 Hz or <= 16 ms at 60 Hz |
| Pointer-to-ink preview | <= 16 ms p95 |
| Edit-to-visible-result | <= 50 ms p95 for local edits |
| Playback scheduling jitter introduced by the app | <= 2 ms p99 after warm-up |
| Audio underruns | 0 during a 30-minute automated playback run |
| MIDI input to visible feedback | <= 35 ms p95 after calibration |
| Microphone onset to provisional feedback | <= 80 ms p95; rich pitch result <= 180 ms p95 |
| Score-follower position error | <= 1 beat for 99% of clean MIDI corpus; recover within 2 measures after a jump |
| Recording recovery | lose no more than the active media chunk after forced refresh |
| Audio/MIDI replay alignment | <= 10 ms median error after calibration |
| Core + GPU resources for a 100-page piano score | <= 200 MB peak on tablet |
| Main-thread long tasks over 50 ms during editing | 0 in the benchmark flow |
| Offline reload | fully usable, including last-open document and piano sound |

Do not claim a budget is met without an automated trace or benchmark artifact. Track Wasm size, Flecs table/entity counts, memory high-water mark, GPU buffer/texture bytes, region-cache hit rate, pipeline compilation, layout invalidation range, compute budget, late audio/input events, confidence, and dropped frames in development builds.

## 13. Testing strategy

### Zig unit and property tests

- Rational-time arithmetic, IDs, command validation, undo/redo, selection.
- Flecs component registration, persistent-ID resolution, relationship integrity, pipeline ordering, deferred mutation, observer invalidation, transient cleanup, and deterministic results across different table layouts.
- Tempo integration, repeat expansion, ties, tuplets, transposition, playback ordering.
- Engraving collision and spacing invariants.
- MIDI/acoustic observation alignment, score-follower jump recovery, confidence thresholds, and recommendation selection.
- Native format round trips and every migration version.
- Take journaling, interrupted chunk recovery, MIDI export, and audio/MIDI replay alignment.
- Deterministic serialization: same model produces identical canonical bytes.

### Import/export corpus

- W3C MusicXML examples plus generated edge cases.
- Public-domain solo, piano, choral, percussion, and orchestral scores.
- MIDI files with tempo changes, sustain, overlapping notes, multiple tracks, and unusual PPQ.
- Malformed XML/ZIP/MIDI fuzz corpus.
- Import -> native -> MusicXML semantic comparison with an explicit allowed-loss report.

### Visual regression

Render fixed pages through WebGPU at standard sizes, read back the final texture, and compare golden images with small, reviewed tolerances. Add focused goldens for MSDF glyphs, staff-line alignment, beams, accidentals, tuplets, ties/slurs, lyrics, collisions, system breaks, annotations, practice feedback, color management, and high-DPI scaling. Test every shader with validation enabled. Never use copyrighted commercial scores as committed goldens.

### Listening and recording corpus

- Exact MIDI performances with controlled early/late/wrong/missed/extra notes, velocity, chords, and pedal.
- Synthetic acoustic renders with tuning offsets, room impulse responses, background noise, speaker leakage, sustain, and different piano samples.
- Human-performed, consented internal fixtures across device microphones; do not commit identifying raw audio without explicit rights.
- Monophonic and polyphonic passages, dense sustain, repeated notes, rests, rubato, jumps, restarts, and lost-position recovery.
- Tests that low-confidence observations remain uncertain rather than becoming false mistakes.
- Simultaneous microphone + MIDI + accompaniment recordings with forced refresh, interruption, storage exhaustion, device removal, and replay/export.

### Browser matrix

- Safari 26+ on supported macOS/iPadOS hardware.
- Current and previous Chrome/Edge on WebGPU-capable macOS, Windows, ChromeOS, and Android devices.
- Current Firefox on Windows and Apple-silicon macOS where WebGPU is enabled by default. Linux and Intel-macOS Firefox are unsupported until release-channel WebGPU is enabled and passes this suite.
- Adapter denial, insufficient limits, device loss, power-preference changes, and GPU-process recovery.
- Installed PWA and ordinary tab where applicable.
- Online, offline, slow network, storage pressure, refresh mid-save/recording, audio/MIDI device change, microphone denial/revocation, background/foreground, split view, keyboard, touch, and pen.

The launch gate tests `navigator.gpu`, adapter acquisition, required limits, and device creation. There is no alternate renderer. Use Playwright for portable flows and manual device passes for Pencil/pen latency, audio/MIDI/microphone capture, installation, storage eviction behavior, and accessibility.

### Accessibility

- Automated WCAG checks for the DOM interface.
- Complete keyboard path for create/import/edit/play/export.
- VoiceOver on Safari/macOS and iPadOS; NVDA or Narrator on Windows.
- Focus recovery after dialogs and score-surface operations.
- Spoken descriptions for focused measure, staff, note/rest, duration, pitch, voice, and annotation.

## 14. Delivery phases

Each phase ends with a runnable URL and passing acceptance criteria. Do not build broad palettes before the vertical slice is playable.

### Phase 0 — foundation

- Add license, README, formatting, CI, dependency lockfile, and reproducible Zig/Vite builds.
- Keep the Flecs 4.1.6 Git submodule pinned; compile the minimal custom build for native and Wasm tests.
- Build `score_core.wasm`, create the Flecs world/pipeline, and call a version/capability function from a Worker.
- Establish binary protocol tests, browser feature detection, error boundary, logging, and performance marks.
- Define the platform/GPU facades, create a WebGPU device/surface, compile a WGSL pipeline, and handle an intentional device-loss test.
- Add PWA manifest, HTTPS local development, and an offline shell.
- Add Bravura with its license and one tiny public-domain fixture.

Done when the hosted/offline app extracts a Flecs-owned render entity into a platform-neutral packet and displays it through WebGPU in the supported browser matrix.

### Phase 1 — read-only vertical slice

- Minimal score model and MusicXML/MXL parser.
- Common piano notation layout, MSDF font assets, and WebGPU notation renderer.
- Library, import flow, score viewport, zoom, page/continuous modes.
- IndexedDB snapshot and crash-safe reopen.
- Import report with unsupported-element counts.

Done when a multi-page public-domain piano score imports, renders, scrolls smoothly, reloads offline, and exports its native package.

### Phase 2 — piano playback

- Playback timeline, transport, cursor, seek, tempo, metronome, loop, count-in.
- AudioWorklet sampler and licensed/basic piano voice.
- Repeats, endings, tempo changes, ties, dynamics, sustain.
- Background/foreground and audio-interruption recovery.

Done when a 30-minute stress score produces no underruns and cursor/audio synchronization passes the defined budget.

### Phase 3 — listening, recording, and coaching

- MIDI input and microphone permission/calibration flows behind `InputBackend`.
- Real-time-safe audio front end, WebGPU FFT/CQT compute, score follower, confidence model, and live feedback.
- `Take` ECS components/events and crash-safe MIDI/audio chunk journaling.
- Simultaneous audio/MIDI/app-stem recording, synchronized replay, compare, and export.
- Post-take heatmap, timing/pitch/pedal diagnostics, and linked practice recommendations.

Done when clean MIDI meets the score-following budgets, microphone inference passes the acoustic corpus without overconfident false errors, and a simultaneous audio+MIDI take survives refresh and replays in sync.

### Phase 4 — annotations and performance mode

- Pen/highlighter/eraser/lasso/text tools and independent overlay.
- Stable score/page anchors and annotation serialization.
- Tablet gestures, palm-rejection settings, performance mode, page turns.
- PDF viewer/annotation path with no semantic-playback claim.

Done when annotations survive zoom, reflow, refresh, offline use, and native export/import on iPad and desktop browsers.

### Phase 5 — common notation editing

- Selection model, command transactions, undo/redo.
- Note/rest entry, duration, pitch, accidentals, ties, articulations.
- Measures, clefs, keys, meters, tempo, dynamics, text, lyrics, chord symbols.
- Keyboard, touch palette, and optional MIDI input.
- Incremental relayout and MusicXML export.

Done when a user can create and edit a short piano score without raw data loss, and every edit round-trips through undo/redo and native persistence.

### Phase 6 — “Holocene” user flow and interoperability hardening

- Add the first-run lawful-import card and licensed-fixture test hook.
- Run the “Holocene” acceptance test without committing or deploying the work.
- Expand MusicXML corpus and error explanations based on real imports.
- Add standard MIDI import/export and quantization review.
- Extend the completed native GPU-to-A4 PDF export to the browser host with
  browser-independent page layout.

Done when the user can import their lawful copy, play, record, receive feedback, annotate it offline, export it, and reopen it on another supported browser.

### Phase 7 — accounts and anywhere sync

- OIDC sign-in, Zig sync service, PostgreSQL, object storage, migrations, backups.
- Idempotent upload/download, offline queue, conflict copies, device revocation.
- Privacy/export/delete controls, observability, quotas, abuse controls.
- End-to-end tests across two browser contexts and interrupted networks, including MIDI-only take sync and explicit audio-recording consent.

Done when an edit made offline on one device appears after sign-in on another without losing either device’s work.

### Phase 8 — public release

- Security review, dependency/license audit, fuzz soak, accessibility audit.
- Browser/device performance certification against the budgets.
- Content-rights review and third-party notices.
- Staged rollout, rollback plan, status page, backups, and recovery drill.

## 15. Release gates

A public v1 is ready only when all are true:

- No known critical/high security issue.
- No known operation that silently loses supported notation.
- Local editing works without an account and without a network.
- Export-all works before sign-in or data deletion.
- Crash/refresh recovery and format migrations have automated coverage.
- Audio, rendering, latency, and memory budgets pass on the named devices.
- MIDI/microphone assessment confidence and recording/recovery budgets pass on the named devices.
- Unsupported WebGPU browsers receive a complete compatibility explanation and export/support path, not a broken editor.
- Keyboard and screen-reader critical paths pass.
- “Holocene” content is either user-supplied or covered by documented rights.
- All fonts, samples, icons, code, and example scores have recorded licenses.
- Production is HTTPS, immutable assets are content-hashed, and rollback is tested.

## 16. Main risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Engraving scope expands without bound | Publish supported-element matrix; prioritize piano/common notation; preserve/report unsupported imports. |
| WebGPU excludes some browsers/devices | Make the requirement explicit before import/sign-in; maintain a tested support table; provide no misleading degraded editor. |
| GPU device loss or driver differences | Central resource registry, async pipeline creation, validation, device-loss rebuild, adapter/limit telemetry without score content. |
| WebGPU effects reduce notation clarity | Golden tests, print geometry separation, contrast budgets, reduced-motion/effects settings, no effect may move notation. |
| Runtime font/shaping scope grows | Reproducible MSDF build, explicit Unicode coverage, shaping tests, versioned font assets. |
| Browser audio differs by device | AudioWorklet, bounded scheduling, user-gesture activation, device matrix, interruption recovery. |
| Acoustic piano inference reports false mistakes | Score-constrained follower, source-aware confidence, uncertainty UI, calibrated corpus, MIDI preferred when present. |
| Recordings exhaust quota or expose sensitive audio | Chunked writes, quota forecast, local-only default, explicit audio-sync consent, per-take deletion/export. |
| iPad storage is evicted | Persistent-storage request, visible local/sync state, frequent portable export, optional sync. |
| Wasm/JS boundary dominates | Coarse binary messages and draw lists, worker ownership, batch profiling. |
| Flecs runtime layout leaks into files | Stable persistent IDs and explicit schema; never serialize Flecs tables, IDs, pointers, or snapshots directly. |
| MusicXML round trips lose detail | Corpus tests, source retention, semantic diff, explicit loss report. |
| Copyright blocks the requested first song | User-supplied import now; bundle only with written distribution rights. |
| Cross-device conflicts corrupt music | Idempotent operations, optimistic revisions, preserved conflict copies, no silent auto-merge. |
| Platform ports fork the core | Enforce facade-only platform imports and run the same native/Wasm core fixtures in CI. |

## 17. First implementation slice

The first code change after this plan should contain only:

1. `build.zig` compiling the pinned Flecs custom build and producing `score_core.wasm` from Zig 0.16.0.
2. A Flecs world with explicit phases and one persistent demo document entity graph.
3. A typed Worker bridge that verifies the ABI and platform-facade versions.
4. A Preact shell with Library and Editor routes plus an unsupported-WebGPU screen.
5. A responsive WebGPU score surface rendering a Zig/Flecs-generated staff, clef, and notes through one WGSL/MSDF pipeline.
6. IndexedDB storage for one explicit-schema demo document; no serialized Flecs state.
7. PWA manifest and Service Worker with an offline reload test.
8. Unit, native/Wasm integration, WebGPU golden, and Playwright smoke tests.

This slice proves the risky seams—Zig/Flecs integration, portable facades, Wasm ABI, worker messaging, WebGPU, storage, responsive UI, and offline caching—before implementing a large notation surface.

## 18. Primary references

- [Zig official downloads — 0.16.0 stable](https://ziglang.org/download/)
- [WebAssembly Core Specification](https://www.w3.org/TR/wasm-core/)
- [Flecs v4.1.6 tag](https://github.com/SanderMertens/flecs/tree/v4.1.6)
- [Flecs systems and pipelines](https://www.flecs.dev/flecs/md_docs_2Systems.html)
- [Flecs observers and events](https://www.flecs.dev/flecs/md_docs_2ObserversManual.html)
- [WebGPU](https://www.w3.org/TR/webgpu/)
- [WebGPU Shading Language](https://www.w3.org/TR/WGSL/)
- [Web Audio API](https://www.w3.org/TR/webaudio-1.0/)
- [Media Capture and Streams](https://www.w3.org/TR/mediacapture-streams/)
- [MediaStream Recording](https://www.w3.org/TR/mediastream-recording/)
- [Web MIDI API](https://www.w3.org/TR/webmidi/)
- [High Resolution Time](https://www.w3.org/TR/hr-time-3/)
- [Pointer Events](https://www.w3.org/TR/pointerevents/)
- [Indexed Database API](https://www.w3.org/TR/IndexedDB/)
- [Service Workers](https://www.w3.org/TR/service-workers/)
- [Web Application Manifest](https://www.w3.org/TR/appmanifest/)
- [MusicXML 4.0](https://www.w3.org/2021/06/musicxml40/)
- [SMuFL 1.4](https://www.w3.org/2021/03/smufl14/)
- [Bravura license](https://github.com/steinbergmedia/bravura/blob/master/LICENSE.txt)
- [StaffPad product reference](https://www.staffpad.net/)
- [forScore annotation reference](https://forscore.co/documentation/annotation/)
- [Soundslice feature reference](https://www.soundslice.com/features/)
- [Melodics practice/feedback reference](https://melodics.com/how-it-works)
- [Apple App Review intellectual-property guidance](https://developer.apple.com/app-store/review/guidelines/)
