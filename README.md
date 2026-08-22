# Score

Score is a game-style, local-first notation and piano-practice application. The score scene, product UI, hit testing, transport, recording model, assessment, persistence, and hot-reloadable systems are Zig/Flecs code. macOS presents the shared render packets through Dawn/Metal; the browser presents them through WebGPU. There is no DOM application UI, Canvas 2D, WebGL, or software renderer.

The current build can import MusicXML/XML/MXL, standard MIDI, and portable `.score` documents; preserve timed lyrics and optional vocal-guide cues separately from instrument notes; render and page through a grand staff; insert, select, move, delete, undo, annotate, loop, count in, adjust tempo, play, record microphone audio plus synchronized MIDI, replay a take, and assess live MIDI or detected microphone pitch. The shared semantic control tree is exposed through NSAccessibility, browser accessibility controls, and UIAccessibilityElement. Browser state stays in IndexedDB and the installable PWA works offline after its first successful load. Native state and captured audio stay under `~/Library/Application Support/Score`.

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
- `-` / `+`: tempo down/up; the GPU buttons do the same
- Loop: isolate/toggle the measure containing the cursor; Click: toggle the metronome
- Page Up / Page Down or scroll: move through score pages
- Read: select a note; Edit: insert a note
- Arrow keys: move the selected note in pitch or quarter-beat time
- Delete/Backspace: delete selection; Command/Ctrl-Z and Command/Ctrl-Y: undo/redo
- Ink: pressure-aware page-anchored annotation
- Play: compare MIDI or microphone input with the score
- Record: capture real audio and timestamped MIDI together
- Voice button or `V`: show/hide the optional singer pitch guide; guide notes do
  not enter piano playback, keyboard fingering, or piano assessment

## Offline reference-audio analysis

Analyze a lawful local PCM WAV and optionally compare its evidence with a
MusicXML/MXL score:

```sh
zig build audio-analyze -Doptimize=ReleaseFast -- reference.wav \
  --score authorized-score.mxl --output local-content/analysis.json
```

The versioned JSON contains onset/tempo evidence, bass and polyphonic pitch
candidates, normalized chroma, and an alignment summary. It is deliberately
labeled a review aid rather than an authoritative automatic transcription.
The tool does not download streaming audio; keep private recordings and reports
under the ignored `local-content/` tree.

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
