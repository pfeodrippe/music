# Score app — agent checklist

This file is the durable hand-off checklist for the project. Keep it current as
work lands; do not infer completion from a prototype screenshot.

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
- [ ] Hot-reload WGSL/Metal shader pipeline edits with validation and last-good
  pipeline retention.
- [x] Prove hot reload interactively without losing imported score, transport,
  annotation, or current practice take.

## Notation and visual quality

- [x] Shared Inter + Bravura MTSDF atlas on every GPU backend.
- [x] UTF-8 decoding and Latin-1 UI glyphs.
- [x] Real SMuFL clefs, time-signature digits, noteheads, stems, flags, and
  ledger lines.
- [x] Separate engraving anchors for staff, clef, meter, notes, barlines, and
  playback cursor.
- [ ] Add beams, rests, dots, accidentals, ties/slurs, articulations, dynamics,
  tuplets, key signatures, and multi-voice collision handling.
- [ ] Replace fixed two-system pagination with measure-aware horizontal spacing
  and responsive system/page breaking.
- [ ] Add zoom, pan, page/continuous modes, part selection, and print layout.
- [ ] Run repeated native visual QA at desktop, iPad, and narrow widths.

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
  score pages and prove that the native importer accepts its 1,874 events.
- [x] Emit `local-content/holocene/Holocene-private-study.mxl` as a standard
  compressed MusicXML container; verify title, native import, guided keyboard,
  and playback start/stop end-to-end. Correct the supplied eighth-note = 132
  marking to MusicXML quarter-note = 66 rather than the erroneous 132 QPM.
- [x] Add `scripts/audit-musicxml.py` and generate ignored JSON/Markdown audit
  ledgers. After meter, full-rest, cross-staff contamination, and visible
  duration repairs, the current 1,861-element draft still correctly reports
  `FAIL`: 229 structural/OMR flags across 99 measures. Do not waive this gate.
- [x] Re-import the corrected 66-QPM private MXL in the signed native app and
  visually verify GPU notation, guided keys, pedal indicators, and playback
  start/stop; keep the import warning visible while the audit fails.
- [ ] Finish local, gitignored Holocene MusicXML/MXL from the 12 user-supplied
  score-page images; treat the official recording as timing/structure reference,
  not as authority for redistributable notation.
- [ ] Produce and clear a page/measure audit of every meter, rhythm, pitch,
  accidental, tie, articulation, dynamic, lyric alignment, and staff assignment
  against all 12 supplied pages before calling the private Holocene score
  complete; record every unresolved ambiguity instead of silently guessing.
- [ ] Turn the supplied voice-and-harp source into an intentional professional
  two-hand piano reduction, preserving the accompaniment and melody while
  documenting any octave, voicing, or playability changes.
- [x] Preserve MusicXML lyric syllables/words as timed GPU-rendered text and
  round-trip them through MusicXML and portable `.score` documents.
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
  chords, gaps, and ties; regression-test export then re-import.
- [x] Playback, tempo, loop, count-in, metronome, and software piano synth.
- [x] Add `score-audio-analyze`, a Zig 0.16 offline WAV analyzer with local
  downmix/resampling, onset and tempo evidence, bass/chroma/polyphonic pitch
  candidates, JSON output, and MusicXML/MXL alignment that ignores vocal-guide
  notes. Validate the end-to-end CLI on generated PCM audio; label its output as
  evidence rather than an authoritative transcription.
- [ ] Add phase-aware source separation, learned multi-pitch transcription,
  section/beat alignment, confidence heatmaps, and manual correction workflow
  for user-owned reference audio. Never download/rip protected streaming audio;
  accept lawful local exports and keep them ignored/private.
- [ ] Build the production audio path as a general multi-sampled instrument
  engine, not a piano-only special case: reusable key/velocity zones,
  round-robin groups, articulations, envelopes, filters, LFO/modulation matrix,
  streaming, buses, effects, automation, and per-instrument metadata. Make the
  concert grand the first reference-quality library, then support electric
  pianos, organs, strings, percussion, and licensed/user sample packs without
  changing the score or transport core.
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
- [ ] Support MIDI CC64 sustain including continuous half-pedal, CC66 sostenuto,
  CC67 una corda, pedal noise, repedaling, per-note sustain state, and captured
  pedal automation in recorded takes and MIDI import/export.
- [x] Route MIDI CC64/66/67 through the native and browser real-time queues;
  implement sustain release, sostenuto latching, una-corda diagnostic timbre,
  recording capture, and live three-pedal position indicators. Production
  half-pedal/resonance/noise behavior remains part of the sampler milestone.
- [ ] Render standard score pedal marks/lines and a toggleable three-pedal guide
  that clearly previews when to press, half-press, change, and release each
  pedal; show live hardware pedal position and flag missed/late pedal changes in
  practice feedback.
- [ ] Add sampler quality/performance tests: offline reference renders, velocity
  transition and pedal-state tests, no-dropout stress tests, deterministic MIDI
  replay, latency calibration, spectral/regression comparisons, and blind
  listening checks on studio monitors/headphones across Mac, browser, and iPad.
- [ ] Treat sample provenance, redistribution license, download size, integrity
  hashes, optional asset packs, and offline installation as release-blocking;
  never ship an unclear or non-redistributable piano library.
- [x] MIDI input/output and microphone pitch observation.
- [x] Practice assessment for pitch and timing.
- [x] Audio + MIDI take recording and replay.
- [x] Read/edit/ink/practice tools, selection, insertion, movement, deletion,
  annotations, undo, and redo.
- [ ] Extend MusicXML export to preserve every engraving detail plus
  fingering/annotation data beyond the current note-level round trip.
- [ ] Robust polyphonic microphone transcription and calibrated latency model.
- [ ] Practice history, difficult-measure heatmap, and actionable phrase-level
  coaching.

## Cross-platform verification

- [x] macOS Dawn/Metal application bundle builds and launches.
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
