# Score

Score is a game-style, local-first notation and piano-practice application. The score scene, product UI, hit testing, transport, recording model, assessment, persistence, and hot-reloadable systems are Zig/Flecs code. macOS presents the shared render packets through Dawn/Metal; the browser presents them through WebGPU. There is no DOM application UI, Canvas 2D, WebGL, or software renderer.

The current build can import MusicXML/XML/MXL, standard MIDI, and portable `.score` documents; preserve timed lyrics and optional vocal-guide cues separately from instrument notes; render and page through a properly braced piano grand staff; insert, select, move, delete, undo, annotate, loop, count in, adjust tempo, play, record microphone audio plus synchronized MIDI, replay a take, and assess live MIDI or detected microphone pitch. The shared semantic control tree is exposed through NSAccessibility, browser accessibility controls, and UIAccessibilityElement. Browser state stays in IndexedDB and the installable PWA works offline after its first successful load. Native state and captured audio stay under `~/Library/Application Support/Score`.

## Toolchain

- Zig 0.16.0, the current official stable release
- Flecs 4.1.6 at commit `fb55f3c25660425cfe1bc4cf5e6bff8b3f18a9b8`
- Emscripten 4.0.20 with Emdawnwebgpu for the browser export
- Xcode command-line tools for the macOS and iOS builds

Initialize the pinned dependency once:

```sh
git submodule update --init --recursive
```

## Native macOS

Build, test, and launch the ad-hoc signed app bundle:

```sh
zig build test
zig build macos-bundle
open zig-out/Score.app
```

`zig build -Doptimize=ReleaseSafe` builds the native executable and statically links the same system descriptors used in development. `zig build dev` launches a Debug build and watches reloadable systems: a valid dylib is installed at a frame boundary while the Flecs world remains alive; a failed build leaves the previous system running.

The development host uses its own atomic `autosave-dev.score` journal. That
journal survives watcher-driven process relaunches but is isolated from the
release app's `autosave.score`, so an older open app window cannot overwrite the
score being exercised through hot reload.

In a Debug session, `zig-out/bin/score-devctl sampler state` reports sampler
regions, preload count, queue/overload faults, and the acoustic detail values
actually consumed by the audio thread. Tune the supported Salamander profile
without restarting with `sampler detail studio`, `sampler detail dry`, or four
explicit CC20...23 values such as `sampler detail 64 64 64 64`.

`zig-out/bin/score-devctl fingering state` reports the phrase anchor used by the
GPU virtual-piano guide for each hand; `fingering chord` reports every current
and next chord pitch/finger pair. The allocation-free guide combines a short
phrase optimizer for direction, spans, crossings, repetitions, and black-key
ergonomics with exhaustive distinct-finger assignment for each playable
single-hand chord. It excludes rests and vocal-guide cues and explicitly marks
voicings above five distinct tones for hand redistribution. Standard
MusicXML/MXL fingering overrides are imported, persisted, exported, and used
for the matching guide tone. In Edit mode, press `1`...`5` on a selected note
to author a finger or `0` to restore automatic guidance; the live equivalent is
`zig-out/bin/score-devctl fingering set NOTE_ID 1..5|clear`.

For repeatable ink/reflow QA without GUI automation, `score-devctl ink dot BEAT
HEIGHT` creates a removable score-space mark (`HEIGHT` is 0...1 across the
voice-plus-piano system), and `score-devctl ink undo` removes it. This Debug-only
path exercises the same annotation store and GPU renderer as Pencil/mouse ink.

Debug framebuffer readback writes the real Dawn/Metal result as an uncompressed
top-down BMP. Use an honest extension, for example
`zig-out/bin/score-devctl capture tmp/native-frame.bmp`; other extensions are
rejected instead of receiving mislabeled bitmap bytes.
For deterministic responsive-layout QA, `score-devctl window WIDTH HEIGHT`
resizes the real Debug window within its supported 720...3840 by 540...2160
logical-point range before capture.

Paged layout uses the actual score-stage height everywhere. With the guided
piano visible, a constrained window shows one complete voice-plus-piano system;
hiding the piano or using a taller window allows two systems when their full
clefs, meters, lyrics, and grand staves fit. Page counts, playback following,
turn controls, hit testing, and annotations all use that same responsive map.

## WebGPU/Wasm PWA

With Emscripten 4.0.20 active:

```sh
zig build web
python3 -m http.server 8080 --directory build/web
```

Open `http://localhost:8080/` (or `score.html`). `zig build dev-web` rebuilds and serves the export, autosaving the world before a development refresh and restoring it afterward. The generated shell contains only the presentation canvas and launch metadata. A browser without WebGPU receives a diagnostic page; it never enters an alternate renderer.

`build/web` is a self-contained static deployment. Production hosting must use HTTPS, preserve the supplied `_headers` where supported, and serve `.wasm` as `application/wasm`; no application server is required. Publish the complete directory so the Service Worker can make the studio available offline.

## iOS/iPadOS

```sh
zig build ios-core
zig build ios-app
zig build ios-simulator
```

`ios-core` produces `zig-out/lib/libscore-ios-core.a` and `zig-out/include/score_ios.h`. `ios-app` adds the arm64 UIKit lifecycle, CAMetalLayer renderer, AVAudioEngine, CoreMIDI, Pencil/touch/mouse/keyboard input, system document panels, and local recovery under `build/ios/Score.app`; set `SCORE_IOS_SIGN_IDENTITY` to a valid identity for device signing. `ios-simulator` creates an ad-hoc signed arm64 simulator bundle under `build/ios-simulator/Score.app`. UIKit is only the lifecycle/device host—the product UI remains the same Zig/Flecs GPU scene.

## Controls

- Space or the center transport button: play/pause with count-in
- `-` / `+`: tempo down/up; the GPU buttons do the same. Click the displayed
  tempo to type a value. The note value is explicit (`1/4 = 147 BPM`, for
  example), while playback/MIDI use the equivalent quarter-note rate.
- Loop: isolate/toggle the measure containing the cursor; Click: toggle the metronome
- Page Up / Page Down, Left / Right in Read mode, or scroll: advance the score
- `M` or the view button: cycle paged, continuous-system, and two-page spread views
- `[` / `]` or the GPU minus/plus controls: zoom the score between 65% and 105%;
  zoom also reflows complete authored measures so zooming out actually reveals
  more music instead of shrinking the same sparse page
- `F` or Focus: dedicate the window to the score and transport; the piano,
  library, tool rail, and coach return when focus mode is exited
- Read: select a note; Edit: insert a note
- Arrow keys: move the selected note in pitch or quarter-beat time
- Delete/Backspace: delete selection; Command/Ctrl-Z and Command/Ctrl-Y: undo/redo
- Ink: pressure-aware annotation anchored to musical time, so new marks follow
  their beat through zoom and responsive page reflow; legacy page-relative ink
  remains readable
- Play: compare MIDI or microphone input with the score
- Record: capture real audio and timestamped MIDI together
- Voice button or `V`: show/hide the optional singer pitch guide; guide notes do
  not enter piano playback, keyboard fingering, or piano assessment. Imported
  lyrics occupy a dedicated lane below that guide staff and cannot share the
  piano grand staff.

## Offline reference-audio analysis

Score-facing offline operations are deliberately consolidated in Zig. Use the
single workbench for semantic inspection, candidate transformation, and direct
comparison with retained pitch-event CSV evidence:

```sh
zig build score-workbench -- inspect authorized-score.mxl
zig build score-workbench -- evidence authorized-score.mxl \
  --csv guitar_basic_pitch.csv --csv piano_basic_pitch.csv \
  --start-beat 0 --end-beat 42 --quarter-bpm 147
```

The former Python pipeline described in older implementation history is
retired and no longer part of `scripts/`; do not add new standalone score tools.

Analyze a lawful local PCM WAV and optionally compare its evidence with a
MusicXML/MXL score:

```sh
zig build audio-analyze -Doptimize=ReleaseFast -- reference.wav \
  --score authorized-score.mxl --output local-content/analysis.json
```

The versioned JSON contains the detected active-audio range (so leading capture
silence does not shift the score), global and ranked tempo evidence, a rolling
16-second tempo trace, bass and polyphonic pitch candidates, normalized chroma,
and an alignment summary. It is deliberately labeled a review aid rather than
an authoritative automatic transcription.
The tool does not download streaming audio; keep private recordings and reports
under the ignored `local-content/` tree.


On macOS, an authorized browser or application stream can be captured through
an installed **BlackHole 16ch** loopback device and analyzed with one command:

```sh
scripts/capture-browser-reference.sh local-content/reference/song.wav \
  --duration 60 --score local-content/reference/song.mxl
```

For a preconfigured aggregate or multi-output route, keep BlackHole as the
recording input while selecting the route independently:

```sh
scripts/capture-browser-reference.sh local-content/reference/song.wav \
  --duration 60 --device 'BlackHole 16ch' \
  --output-device 'Aggregate Device'
```

Start playback when the command prints `CAPTURE READY`. The helper discovers
BlackHole's current AVFoundation index, records lossless 24-bit PCM, and always
restores the previous macOS output device—even if capture is interrupted. It
allows audio applications to follow the output-device change, rejects silent
or prematurely-ended captures before analysis, and refuses to overwrite an
existing recording. Use
it only for audio you may analyze and keep private captures under the ignored
`local-content/` tree.

## Architecture

```text
                 Zig 0.16 + Flecs 4.1.6 core
 score/model · commands · import · timeline · coach · persistence
                           │
              immutable GPU/audio/input facades
               ┌───────────┼───────────┐
               │           │           │
        macOS Dawn/Metal  WebGPU/Wasm  iOS C/Metal seam
        CoreAudio/MIDI    WebAudio/MIDI AVAudio/CoreMIDI
```

The canonical WGSL shader is `src/render/shaders/ui.wgsl` and is embedded into both native and WebGPU builds. Durable files serialize stable IDs and value components, never Flecs entity IDs or platform handles.

## Content rights

The repository contains no copyrighted notation, lyrics, recording, album art, or imitation arrangement for “Holocene” by Bon Iver. The in-app card is a lawful import workflow: provide MusicXML, MXL, MIDI, or `.score` content you are authorized to use. A redistributable song may be bundled only after its written rights record is added under `legal/content-licenses/`.

See [IMPLEMENTATION.md](IMPLEMENTATION.md) for the delivered architecture, file format, test strategy, and remaining release work.
