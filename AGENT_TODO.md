# Score app — agent checklist

This file is the durable hand-off checklist for the project. Keep it current as
work lands; do not infer completion from a prototype screenshot.

Current release gate: finish and verify the native macOS build first. Wasm and
iOS remain later portability targets and must not distract from native quality.

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
- [x] Hot-reload native WGSL pipeline edits through Dawn with asynchronous
  validation, exact diagnostics, and last-good pipeline retention. Prove both
  invalid WGSL and a missing entry point keep the PID, Flecs world, and rendered
  frame alive; expose `shader reload|state` through `score-devctl`.
- [ ] Add the equivalent development-time last-good Metal shader reload path to
  the deferred iOS host after the native release gate clears.
- [x] Prove hot reload interactively without losing imported score, transport,
  annotation, or current practice take.

## Notation and visual quality

- [x] Shared Inter + Bravura MTSDF atlas on every GPU backend.
- [x] UTF-8 decoding and Latin-1 UI glyphs.
- [x] Real SMuFL clefs, time-signature digits, noteheads, stems, flags, and
  ledger lines.
- [x] Render clef-aware key signatures with up to seven SMuFL flats or sharps
  on both staves and reserve engraving space before the meter/music origin.
- [x] Import semantic MusicXML `<harmony>` events (root/kind/display text,
  slash bass, inversion, and offset), persist them in portable `.score` v11,
  render chord symbols with SMuFL accidentals, and export/re-import them.
- [x] Separate engraving anchors for staff, clef, meter, notes, barlines, and
  playback cursor.
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
- [ ] Add responsive arbitrary system counts, vertical justification, and
  true multi-page breaking for every viewport and print size.
- [x] Add GPU controls, hot keys, accessibility actions, and Debug socket
  commands for paged, continuous-system, two-page spread, score zoom, and
  distraction-free focus modes. Navigation advances one system in continuous
  mode, one page in paged mode, and one spread in two-page mode.
- [ ] Add free pan, part selection, and print layout.
- [x] Add Debug-only readback of the real native Dawn/Metal framebuffer through
  `score-devctl capture`; use it for deterministic GPU visual regression.
- [ ] Run repeated native visual QA at desktop and narrow widths, then perform
  the deferred iPad pass after native is release-ready.

## Guided piano

- [x] Toggleable five-octave GPU-rendered virtual piano.
- [x] Score-synchronized current and next key highlights for left/right hands.
- [x] Compact current/next finger-number markers aligned to exact keys.
- [x] Click/touch keys to audition through the native/Web audio engine.
- [ ] Improve fingering using phrase-aware optimization (hand span, thumb-under,
  crossing penalties, repeated notes, black-key ergonomics, and staff/voice).
- [ ] Add optional fingering overrides saved as score-local annotations.

## Score library and content

- [x] Remove all hard-coded Holocene/Bon Iver branding from the app UI.
- [x] General offline Score Library modal.
- [x] Bundle Bach Minuet in G (public-domain engraving) and Beethoven Für Elise
  (OpenScore CC0), with sources, rights statements, and SHA-256 records.
- [ ] Add more compact, well-engraved CC0/public-domain piano starters after
  verifying the rights of each specific digital edition/arrangement.
- [x] Generate a private, gitignored two-part MXL draft from all 12 supplied
  score pages and prove that the native importer accepts its initial 1,874
  events; the page-8 through page-12 corrections now import as 2,217 events.
- [x] Emit `local-content/holocene/Holocene-private-study.mxl` as a standard
  compressed MusicXML container; verify title, native import, guided keyboard,
  and playback start/stop end-to-end. Preserve the supplied arrangement's
  quarter-note = 132 marking only as notation-source data. A
  clean temporary Chrome/BlackHole capture of the authorized SoundCloud stream
  yields strong 146.5/148.9 quarter-note candidates, corroborating the
  published 147-148 BPM analyses; encode the recording-calibrated base pulse
  as 147 BPM. A longer recording-derived variable tempo map remains a
  mandatory unfinished gate.
- [x] Add `scripts/audit-musicxml.py` and generate ignored JSON/Markdown audit
  ledgers. After meter, full-rest, cross-staff contamination, and visible
  duration repairs, insert explicit MusicXML `<forward>` spans instead of
  inventing notes for unrecovered OMR time. The current 2,217-event draft now
  passes the structural cursor audit with zero issues, while a separate
  `REVIEW_REQUIRED` ledger retains 114 gaps across 83 part/measures and 86
  original Audiveris rhythm warnings. Structural `PASS` is not musical
  accuracy and must never waive those review gates.
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
  The regenerated 174-measure MXL imports as 2,217 events, passes the structural
  audit with zero issues, and retains 114 explicit OMR gaps across 83
  part/measures. The 348-entry source matrix now has 77 page-complete and 271
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
- [x] Re-import the recording-calibrated 147-QPM private MXL in the signed native app and
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
- [ ] Obtain a lawful local copy/export of the official recording for the
  recording-led audit. None is currently present, so do not claim that the
  private OMR draft matches the recording and never rip a streaming service.
- [x] Preserve the user-supplied D-flat/five-flat 6/4 fragment as ignored raw
  OMR evidence and prove native MXL import. Its seven OMR measures fail the
  structural audit (overfilled measures 1-3 and underfilled measure 7), so it
  is not an approved transcription or a basis for pattern-copying a full song.
  Use its chord labels/two-hand texture as secondary arrangement evidence only.
- [x] Create a separate ignored labeled fragment candidate that adds the five
  visible chord changes without altering the raw OMR. Native dev-control import
  reports 83 notes / 5 harmonies; its audit intentionally remains `FAIL` with
  four duration issues (measures 1-3 overfilled, measure 7 underfilled).
- [ ] Build a section/timestamp verification ledger against the lawfully played
  official recording, with confidence and unresolved-ambiguity fields for every
  phrase. Also audit every meter, rhythm, pitch, accidental, tie, articulation,
  dynamic, lyric alignment, and staff assignment against the supplied pages as
  secondary evidence. A section is not complete until the recording-led audit
  clears; never silently guess.
- [ ] Stitch the high-resolution independent-page OMR passes as secondary
  evidence. The combined multi-page pass demonstrably dropped dense two-hand
  texture on later pages (especially the arpeggiated accompaniment), so it must
  not be promoted or used to claim completeness.
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
- [ ] Import the corrected private file in the app and verify playback, cursor,
  guided keyboard, and both hand tracks end-to-end.

## Editing, practice, and capture

- [x] MusicXML, MXL, MIDI, and portable `.score` import.
- [x] MusicXML export with two-staff/voice structure, tempo, meter, key,
  chords, gaps, ties, explicit rests, tuplets, dynamics, slurs, articulations,
  and fermatas; regression-test export then re-import.
- [x] Preserve disjoint imported-part staff/voice tracks before projecting them
  onto a two-staff MusicXML export. Regression-test an overlapping vocal-guide
  rest and piano upper staff, then prove the private acceptance export has
  zero overfilled bars and preserves all 1,286 sounding note onsets.
- [x] Preserve the imported measure map and every mid-score meter change through
  the core model, portable `.score` v12 persistence, live hot-reload ABI,
  MusicXML export, bar/beat display, measure looping, and metronome accents.
  The private export/re-import now remains 175 measures, retains all 17 emitted
  time-signature entries (including each 2/4 to 4/4 return), preserves all
  1,286 sounding onsets, and passes the structural audit with zero issues.
- [x] Playback, tempo, loop, count-in, metronome, and software piano synth.
- [x] Honor connected MusicXML tie chains in the playback timeline: suppress
  intermediate note-off/on re-attacks across exported measure segments while
  retaining safe attacks/releases for dangling OMR tie marks.
- [x] Derive non-loop playback bounds from the live Flecs score, stop exactly
  at the final event, emit final-frame notes before all-notes-off, and restart
  from beat zero/count-in when Play is pressed at the end. Cover this with a
  regression test and native visual verification.
- [x] Add `score-audio-analyze`, a Zig 0.16 offline WAV analyzer with local
  downmix/resampling, leading/trailing silence detection, ranked global tempo
  plus a rolling 16-second tempo trace, bass/chroma/polyphonic pitch candidates,
  JSON output, and MusicXML/MXL alignment that ignores vocal-guide notes.
  Validate the end-to-end CLI on generated PCM audio; label its output as
  evidence rather than an authoritative transcription.
- [x] Add a reusable macOS Chrome/app -> BlackHole -> PCM24 WAV -> Zig analysis
  workflow. Discover the current AVFoundation loopback index, refuse accidental
  overwrite, accept any optional MXL/MusicXML comparison, and restore the user's
  original output device from success, failure, or signal paths.
- [x] Add deterministic chroma-overlap alignment for split reference captures,
  including active-audio offsets, best/runner-up similarity evidence, and a
  deliberately non-certifying review status. Cover the timing map and frame-rate
  validation with standalone regression tests.
- [ ] Add phase-aware source separation, learned multi-pitch transcription,
  section/beat alignment, confidence heatmaps, and manual correction workflow
  for user-owned reference audio. Never download/rip protected streaming audio;
  accept lawful local exports and keep them ignored/private.
- [ ] Finish a measure-by-measure, recording-led arrangement audit for the
  private Holocene study score. The playable piano part must be a musically
  coherent two-hand reduction of the recording's piano/harp accompaniment—not
  a direct copy of one scanned staff—and must carry note, rhythm, voicing,
  dynamics, articulation, and pedal evidence. Keep the vocal melody and lyrics
  on their independent optional singer-guide staff. Leave every unaudited bar
  marked `REVIEW_REQUIRED`; structural MusicXML validity is not musical proof.
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
  finite-PCM checks, eight-point velocity response, sustain/half-pedal/release
  and mechanical-noise probes, exact MIDI attack replay, nonzero-channel input,
  and no-drop/no-unclamped-overload stress. Emit JSON plus a PCM16 evidence WAV
  and fail the build step when a gate fails. Both the V3 fallback and V6.2 live
  preset pass; an exact-digital-silence tail is correctly treated as infinite
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
  measures 33.478 dB across the eight-point velocity sweep, distinct pedal-up/
  half/full release tails using the documented half-pedal curve, mechanical
  pedal sound, exact MIDI attack replay, and zero queue drops/raw-mix overloads.
  Record Chisato Yamauchi/Alexander Holm attribution and CC BY 3.0 under
  `legal/third-party-notices/`. Browser streaming/memory cost, multi-mic sound,
  and blind listening remain open; this is not yet the final reference grand.
- [x] MIDI input/output and microphone pitch observation.
- [x] Practice assessment for pitch and timing.
- [x] Audio + MIDI take recording and replay.
- [x] Use a unique per-process temporary autosave before atomic replacement so
  simultaneous development instances cannot trample the same staging file.
- [x] Read/edit/ink/practice tools, selection, insertion, movement, deletion,
  annotations, undo, and redo.
- [ ] Extend MusicXML export to preserve every engraving detail plus
  fingering/annotation data beyond the current note-level round trip.
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
