# Cross-Platform GPU Music Application — Implementation

Status: working native macOS, WebGPU/Wasm, and iOS/iPadOS Metal implementations

Updated: 2026-08-22

Working name: **Score** (replace before public release)

Core language/runtime: **Zig 0.16.0 + Flecs 4.1.6**

Primary validation target: **native macOS through Dawn/Metal**

Browser distribution target: **WebAssembly + WebGPU only**, behind the same platform facades

## 0. Implemented baseline

This document started as the architecture plan and now also records the working implementation. The following is present and build-verified:

- A Zig-owned Flecs world with persistent score/session components, replaceable system descriptors, deterministic transport progression, and native frame-boundary dylib reload while the world remains alive.
- A signed macOS `.app` using Dawn/Metal, CoreAudio/AudioUnit, CoreMIDI, AudioQueue microphone capture, native import/export panels, app-support autosave, and WAV take replay.
- A WebGPU-only Wasm/PWA export using Emdawnwebgpu, IndexedDB recovery, Service Worker offline caching, Web MIDI, getUserMedia, MediaRecorder, and a Zig DSP AudioWorklet. No Canvas 2D, WebGL, DOM product controls, or software renderer exists.
- A stable iOS C ABI plus device and simulator application bundles: CAMetalLayer rendering, AVAudioEngine synthesis/metronome/microphone capture, CoreMIDI, system document import/export, atomic recovery, Pencil/touch/mouse input, and external keyboard commands.
- MusicXML/XML, compressed MXL, standard MIDI, and versioned `.score` import; multi-part/polyphonic MusicXML timing; note edits with undo/redo; page-anchored pressure ink; pagination; transport looping/count-in/metronome/tempo; synchronized audio/MIDI takes; pitch/timing practice feedback.
- Standards-based MusicXML 4.0 export, metrical bar alignment even when an OMR
  measure is underfilled, live MIDI CC64/66/67 pedal state, sustain and
  sostenuto semantics in the Zig diagnostic synth, and GPU three-pedal status.
- A shared instanced WGSL renderer with responsive desktop/iPad/phone layout and a generated original PWA/macOS icon.
- A core-owned semantic accessibility snapshot mirrored through NSAccessibility on macOS, hidden semantic DOM controls in the browser, and UIAccessibilityElement on iOS/iPadOS. Actions route back through the same Zig hit-testing path as pointer input.
- Native, web, and iOS build gates plus portable unit/integration tests and a pinned macOS CI workflow.

Release gaps are explicit rather than silently approximated: PDF page import/annotation, a full SMuFL atlas and professional engraving breadth, text/lasso annotation tools, optional cloud sync, App Store provisioning, and production content licensing remain follow-on work. The code must not describe those items as complete until their acceptance tests pass.

The private, gitignored Holocene fixture is also explicitly incomplete. Its
current 12-page OMR-derived MXL is useful for exercising import and playback,
but the generated structural ledger still fails and the source is a voice/harp
edition rather than a finished two-hand piano reduction. It must not be called
professional or accurate until every flagged measure and every musical symbol
has been reviewed against the user-supplied pages.

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

## 2. Copyright and “Holocene”

“Holocene” by Bon Iver is copyrighted. The repository and public deployment must not contain its notation, lyrics, recording, album artwork, or an unlicensed sound-alike arrangement.

The first-song experience will be implemented in one of these lawful ways:

1. Preferred during development: show an **Import your copy of Holocene** card that accepts a MusicXML, MXL, MIDI, or PDF file the user obtained lawfully. The file stays local unless the user explicitly enables sync.
2. Keep a developer-owned licensed fixture under `tests/fixtures/licensed/`, ignored by Git and excluded from builds. Tests locate it through `HOLOCENE_FIXTURE_PATH` and skip cleanly when absent.
3. Bundle the score only after written distribution rights are recorded in `legal/content-licenses/holocene.md`, including territory, term, arrangement, lyrics, and offline-cache rights.

Until option 3 is satisfied, use a public-domain score for automated tests, screenshots, the hosted demo, and first-run fallback. Song title/artist metadata may identify the user’s imported document, but it is not a substitute for rights to the musical work.

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

The installed Zig is already 0.16.0. Xcode is no longer a browser build dependency. It becomes relevant only when a future iOS/macOS host is added.

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
- A failed compile, load, ABI check, or migration keeps the last working module active and reports the error through the GPU developer overlay.
- Browser development rebuilds the Wasm application and performs a live restart from a versioned serialized world snapshot. This avoids making Wasm dynamic linking a production dependency while retaining rapid stateful iteration.
- GPU resources are addressed by stable logical handles and restored/rebound after renderer or shader reloads. Shader compilation errors are non-destructive.
- Release builds import the same module descriptors statically. The watcher, dynamic-library loader, developer overlay, and migration diagnostics are removed, and Zig links the application into one platform binary (or one main Wasm module plus required browser packaging files).
- Reloadable callbacks may not retain Flecs table pointers, iterator pointers, Wasm linear-memory slices, or platform handles beyond the call. Long-lived state must be a registered component or a versioned serialized module block.

### 3.6 Production multi-sampled instrument engine

The existing oscillator synth is a diagnostic renderer only. The production
audio path is a general instrument engine, with the concert grand as its first
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

For offline authoring, `score-audio-analyze` accepts a lawful local PCM WAV and
emits a versioned JSON evidence ledger: onset envelope, tempo estimate, bass
candidate, pitch candidates, normalized chroma, and optional MusicXML/MXL
alignment. Its deterministic Goertzel-based implementation is deliberately a
review aid, not a claim of professional automatic transcription. A later
source-separation/learned transcription stage must preserve confidence and feed
the same manual correction/audit workflow. Streaming-site ripping is outside
the content pipeline; private reference recordings must be supplied locally by
the user and remain ignored.

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

Export audio in its original lossless/encoded track plus a widely playable derived file when available. Export MIDI as Standard MIDI File with tempo/calibration metadata in the native package. Recording audio is opt-in for sync because it is large and sensitive; MIDI/assessment-only sync is the default. Show duration/size/quota before long recordings and write chunks incrementally so a refresh does not lose the whole take.

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
- First-run cards: **Import your copy of Holocene**, **Open a MusicXML file**, **Try a public-domain example**, **Create an empty score**.
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
- Add print/PDF export with browser-independent page layout.

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
