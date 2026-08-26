# Score

Score is a game-style, local-first notation and piano-practice application. The score scene, product UI, hit testing, transport, recording model, assessment, persistence, and hot-reloadable systems are Zig/Flecs code. macOS presents the shared render packets through Dawn/Metal; the browser presents them through WebGPU. There is no DOM application UI, Canvas 2D, WebGL, or software renderer.

The current build can import MusicXML/XML/MXL, standard MIDI, and portable `.score` documents; export MusicXML/MXL, MIDI, `.score`, or the complete score as a paginated A4 PDF; preserve timed lyrics and optional vocal-guide cues separately from instrument notes; preserve separate instrumental source parts instead of superimposing an ensemble onto one staff; render and page through a properly braced piano grand staff; insert, select, move, delete, undo, annotate, loop, count in, adjust tempo, play, record microphone audio plus synchronized MIDI, replay a take, and assess live MIDI or detected microphone pitch. The selected instrumental part controls notation, editing, printable pages, practice assessment, and virtual-piano guidance, while full-document playback and MusicXML/MXL export retain every part. MusicXML grace notes remain non-time-consuming exchange events and engrave as ordered cue-size attacks before their principal note instead of collapsing into a chord; connected cue-size beams, slash, following/previous steal percentages, and make-time survive round trips, while the timing attributes drive native/MIDI performance. Single-note tremolo counts also survive native and MusicXML/MXL round trips, engrave as analytic GPU stem strokes independently from ordinary note beams, and drive repeated native/MIDI attacks at the notated subdivision. Numbered MusicXML crescendo/diminuendo hairpins retain staff ownership, placement, spread, niente and line style through native saves and exchange export; the GPU engraver preserves their opening across responsive system/page breaks. The guided piano shows live and authored soft, sostenuto, and sustain positions, previews the next event across all three pedals, and counts both late attempts and completely missed changes during practice. MusicXML round trips continuous positions for all three pedals; Edit mode records CC64, CC66, and CC67 at the score cursor, while the GPU score shows separate pressure curves and measure heatmaps. The shared semantic control tree is exposed through NSAccessibility, browser accessibility controls, and UIAccessibilityElement. Browser state stays in IndexedDB—including view mode, zoom, reading position, selected part, and visible practice panels—and the installable PWA works offline after its first successful load. Native state and captured audio stay under `~/Library/Application Support/Score`.

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

For a release candidate with the installed concert grand treated as a hard
gate, use `zig build macos-release -Doptimize=ReleaseSafe`. It validates
every referenced sample and the deterministic pack identity, then exercises
velocity response, continuous sustain/half-pedal, repedaling, release/hammer/
pedal/resonance layers, scheduled timing, spectral replay, and overload safety
and produces the signed bundle in the same release gate. The bundle includes repository content and
third-party notices but not the optional 1.96 GB soundbank. A successfully
loaded absolute SFZ path is retained under Application Support, so launching
`Score.app` from Finder keeps the selected piano without depending on a shell
working directory.

For controller layout, sensitivity, Bitwig mapping, finger-drumming practice,
and instrument-specific workflows, see
[`CONTROLLER_LEARNING_GUIDE.md`](CONTROLLER_LEARNING_GUIDE.md).

`zig build -Doptimize=ReleaseSafe` builds the native executable and statically links the same system descriptors used in development. `zig build dev` launches a Debug build and watches reloadable systems: a valid dylib is installed at a frame boundary while the Flecs world remains alive; a failed build leaves the previous system running.

The development host uses its own atomic `autosave-dev.score` journal. That
journal survives watcher-driven process relaunches and is isolated from the
release app's `autosave.score`. Every native build claims a process-lifetime
kernel file lock before creating a native window, Metal renderer, audio device,
or sampler; Debug then claims its local control socket. A duplicate launch exits
immediately and asks a responsive Debug owner to focus its existing window. The
kernel lock remains authoritative even if an obsolete host stops polling or its
control-socket backlog fills, so it cannot leave a second stale, differently
sized window on screen or overwrite the score under test.

Native imports also retain the absolute source path and its content fingerprint
beside the corresponding release or development journal. An explicit launch
document is authoritative and is checkpointed immediately; a later ordinary
launch reloads the tracked MusicXML/MXL source when its fingerprint has changed
or the journal is missing. This prevents an older recovery document from
silently replacing a newer external score while preserving edits made to the
current journal between source-file changes.

In a Debug session, `zig-out/bin/score-devctl sampler state` reports sampler
regions, preload count, dropped/late/raw-overload faults, master-limited frames,
invalid-output repairs, and the acoustic detail values actually consumed by the
audio thread. Tune the supported Salamander profile
without restarting with `sampler detail studio`, `sampler detail dry`, or four
explicit CC20...23 values such as `sampler detail 64 64 64 64`.

`zig-out/bin/score-devctl audio state` reports the actual CoreAudio render and
device rates, buffer/callback sizes, latency and safety frames, AudioUnit
latency, the selected named output, every available output count, and a
conservative estimated output-path latency. Debug `audio output INDEX` moves
only Score to a named CoreAudio device (including an interface, Aggregate
Device, or BlackHole) and restores the prior route if startup fails. This is software and
device configuration evidence; a physical key-to-speaker loopback remains a
separate listening/measurement gate.

Native practice input is explicitly routable instead of accepting an opaque
system default. The GPU coach names the selected CoreMIDI endpoint or default
microphone and its input button cycles all MIDI inputs, each named MIDI source,
and the microphone. In a Debug session, inspect or select the same route with
`score-devctl input state`, `input next`, `input microphone`, or
`input audio INDEX`, or `input midi all|INDEX`. Native audio routes include
every CoreAudio input (for example built-in, interface, iPhone, aggregate, and
BlackHole devices), not just the system-default microphone. The GPU input
action cycles the same named list. Device startup is asynchronous because a
sleeping wireless CoreAudio source can take seconds to resolve; the score,
transport, and GPU renderer remain responsive while the route reports
`switching=1`. Starting a take from a MIDI assessment route opens the default
audio recorder in the background without changing that assessment route. MIDI
running status is isolated per source, so multiple
simultaneous controllers cannot corrupt one another's event stream. Audio take
recording remains available while MIDI is the assessment route; microphone
pitch assessment runs only when the microphone route is selected.
Microphone practice detection is polyphonic: the allocation-free Zig analyzer
tracks up to eight simultaneous piano pitches, reports only new attacks, and
timestamps each detected chord at the center of the captured analysis window.
The scorer compensates that measured age at the active tempo before judging
timing. `input state` exposes the configured input/device rates and buffers,
estimated input latency, analyzer timing, attack count, and latest pitches;
physical acoustic loopback calibration remains a separate release measurement.

`zig-out/bin/score-devctl perf reset` followed by `perf state` measures the
live native surface rather than a synthetic renderer: average/maximum frame
cadence, CPU/command-submission work, Metal drawable-acquisition wait, and
presentation time reported separately, 120 Hz and 60 Hz budget misses (with
0.5 ms timer tolerance), and peak GPU draw-item count. Use it after loading and
navigating a representative large score; the counters deliberately do not
pretend to be Dawn GPU timestamp data.

The native large-score reference pass uses a 195-measure, 2,781-event private
MusicXML document at four visible systems. On this development Mac it measures
3.313 ms average CPU/submit work in ReleaseSafe with 1,573 draw items and no
120/60 Hz budget misses. Chord, voice, accidental, and notation queries are
bounded to binary-searched onset ranges instead of rescanning the whole score.

The same frame-boundary control path can exercise a complete live instrument
swap with `zig-out/bin/score-devctl sampler load PATH.sfz`. The replacement is
parsed by sfizz before CoreAudio is rebound; any load or output-start failure
restores the previous sampler instead of leaving a dangling callback.

Native score playback is scheduled below the visual-frame boundary. The Zig
core carries tempo-aware offsets through a short stable look-ahead; CoreAudio
drains them into an allocation-free min heap and passes exact intra-block sample
delays to sfizz. Live MIDI remains immediate. WebAudio and iOS AVAudio consume
the same portable host-event ABI in the shared Zig sampled-piano engine,
including note timing and CC64/66/67 pedal automation, without changing the
score or transport model.

Run the same native sampler through the offline acceptance gate with:

```sh
zig-out/bin/score-sampler-workbench verify REPORT.json EVIDENCE.wav PIANO.sfz
```

Before trusting a user or development SFZ pack, normalize and audit it with:

```sh
zig-out/bin/score-sampler-workbench inspect-pack PIANO.sfz REPORT.json
```

This is shared Zig code rather than an external conversion script. It expands
bounded recursive SFZ includes and macros, resolves global/master/group/region
inheritance into allocation-free instrument zones, normalizes cross-platform
sample paths, deduplicates assets, validates WAV and FLAC stream metadata,
computes SHA-256 content identities, and reports every missing or invalid
sample. The current Accurate Salamander development pack passes with 641
unique WAV files, 1,704 zones, 1,964,042,398 inspected bytes, zero issues, and
pack identity
`7b87e2ca4946cf077d27f24ce8d97c5ea7d8c90a68502cec363796d0bb552556`.
The macro/include-heavy Salamander V3 fallback independently passes with 641
FLAC files, 1,121 zones, 748,397,030 bytes, zero issues, and pack identity
`00b341f846d6e202aa45e0b88cbc80c03026ec824c1dfb716eb34c58b1f8f4ed`.
Native rendering continues to use sfizz for the SFZ opcodes the portable engine
does not yet implement.

Compile and verify the compact browser/iOS bank with:

```sh
zig build portable-piano
zig build portable-piano-verify
```

The current version-4 bank is a licensed local build artifact and is not committed; the
runtime remains backward-compatible with versions 2 and 3. It
contains 353 deduplicated Salamander samples and 931 regions in 135.3 MiB:
704 attack regions (all 88 keys × eight recorded velocity layers), 68 sampled
damper releases for the damped keys, 88 per-key hammer releases, 69 authored
pedal-resonance regions, and recorded pedal-down/up mechanisms. The build copies
the bank and its attribution into Web and iOS
bundles. The shared Zig callback is allocation-free with 128 layer voices and
implements equal-power interpolation between adjacent recorded velocity
layers, priority-aware de-clicked voice stealing, sample-rate/pitch conversion,
key-position stereo, validated sustain loops, authored SFZ amplitude
attack/decay/sustain/release envelopes, and per-zone SFZ filters (one-, two-,
and four-pole low/high pass plus two-pole band pass/reject, cutoff, resonance,
key tracking, and velocity tracking), sustain/half-pedal release,
repedaling, sostenuto, una corda, room response, DC rejection, and linked
limiting. Pedal resonance follows the continuous CC64 depth; moving the pedal
after an attack excites one sampled resonance layer for each already-sounding
key without duplicating velocity-crossfaded attack voices. User `.scorebank`
replacement is validated before the live bank is changed.

The portable quality gate also reads the packed PCM for each acoustic trigger
class and compares an otherwise identical dry/resonant note render. Current
evidence measures non-silent damper/hammer/resonance assets, 69 authored attack
envelopes, 931 authored release envelopes, and a 0.07945 normalized resonance
delta without clipping. The current Accurate Salamander source authors no
filter opcodes, so its truthful packed filter count is zero; synthetic DSP and
version-compatibility regressions exercise every portable filter path.

The schema-3 report includes the velocity/pedal/acoustic-layer checks, queue
stress, calibrated audible sample-attack latency, and a normalized eight-band
attack fingerprint. The PCM evidence and reports should remain in an ignored
local-content or temporary directory unless their sample license permits
redistribution.

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
`score-devctl pointer down|move|up|cancel X Y [mouse|touch|pen]` drives that
same native pointer path through the hot development channel, which makes GPU
hit maps and drag behavior reproducible without adding a platform-specific UI
automation layer. `score-devctl delete`, `undo`, and `redo` exercise the same
mixed note/pedal edit journal used by the keyboard shortcuts.

Debug framebuffer readback writes the real Dawn/Metal result as an uncompressed
top-down BMP. Use an honest extension, for example
`zig-out/bin/score-devctl capture tmp/native-frame.bmp`; other extensions are
rejected instead of receiving mislabeled bitmap bytes.
For deterministic responsive-layout QA, `score-devctl window WIDTH HEIGHT`
resizes the real Debug window within its supported 720...3840 by 540...2160
logical-point request range before capture. The native host clamps every such
request—and its startup size—to the active display's AppKit/GLFW usable work
area. The limit uses the measured title-bar and border geometry, leaves a
visible resize margin, and is recomputed after a monitor move. `score-devctl
window state` reports content, decorated outer size, position, and work area.

Paged layout uses the actual score-stage height everywhere. With the guided
piano visible, a constrained window shows one complete voice-plus-piano system;
hiding the piano or using a taller window adds up to six vertically justified
systems when their full clefs, meters, lyrics, grand staves, and pedal lanes
fit. Page counts, playback following, turn controls, note editing, hit testing,
and score-space annotations all use that same responsive map. Native Metal QA
includes four piano systems and three independent voice-plus-piano systems at
1400x1100, plus the constrained one-system layout.

Paged zoom is semantic reflow on one paper sheet: zooming out first adds the
next complete score system to the same page, then adds further systems at lower
density steps. It never reveals a second page below or converts paged mode into
a horizontal thumbnail layout. Continuous mode remains a page-free vertically
scrollable surface: wheel/trackpad motion pans fractionally, and dragging in
Read or Practice mode moves the score while a stationary click still selects.
The native Export panel's PDF choice renders every authored
page through the same GPU engraving path into an A4 PDF, independent of the
currently visible page and zoom.

## WebGPU/Wasm PWA

With Emscripten 4.0.20 active:

```sh
zig build web
python3 -m http.server 8080 --directory build/web
```

Open `http://localhost:8080/` (or `score.html`). `zig build dev-web` rebuilds and serves the export, autosaving the world before a development refresh and restoring it afterward. The generated shell contains only the presentation canvas and launch metadata. A browser without WebGPU receives a diagnostic page; it never enters an alternate renderer.

The browser prepares the sampled grand in the background. Press **Play** to
unlock Web Audio; transport waits at the current beat until the worklet and
sample bank are ready. If the first click only focuses an inactive browser
window, the app asks you to press **Play** again instead of advancing silently.
Reloaded sessions always start stopped even though their reading position is
restored.

For a local development fixture, copy an authorized MusicXML/MXL/MIDI/`.score`
file under `build/web` and open
`http://localhost:8080/score.html?score=relative-file.mxl`. The same semantic
import path used by the file picker loads it, saves it to IndexedDB, and removes
the query parameter; an ordinary reload then restores the imported document.
The URL must remain same-origin and the development preload is not bundled
content.

`build/web` is a self-contained static deployment, including the sampled grand
piano bank. Production hosting must use HTTPS, preserve the supplied `_headers`
where supported, and serve `.wasm` as `application/wasm`; no application server
is required. Publish the complete directory so the Service Worker can make the
studio and piano available offline.

The shared allocation-free callback is available as `sample_bank.Instrument`
(`Piano` remains a compatibility alias). Banks with validated sample loop
points sustain held, damper-latched, and sostenuto-latched attack voices with
fractional boundary interpolation, then continue into the recorded tail on
release. Release and pedal-mechanism one-shots never loop.

## iOS/iPadOS

```sh
zig build ios-core
zig build ios-app
zig build ios-simulator
# With one unlocked, paired physical iPad connected:
zig build install-ios-device
# With an iOS Simulator already booted:
zig build dev-ios
```

`ios-core` produces `zig-out/lib/libscore-ios-core.a` and
`zig-out/include/score_ios.h`. `ios-app` adds the arm64 UIKit lifecycle,
CAMetalLayer renderer, AVAudioEngine callback around the shared Zig sampled
piano, CoreMIDI, Pencil/touch/mouse/keyboard input, system document panels, and
local recovery under `build/ios/Score.app`; set `SCORE_IOS_SIGN_IDENTITY` to a
valid identity for direct manual signing. `install-ios-device` auto-detects the
connected iPad, Apple Development identity, and matching provisioning profile,
then embeds, signs, installs, and launches the bundle. Its optional overrides
are `SCORE_IOS_DEVICE`, `SCORE_IOS_PROFILE`, and
`SCORE_IOS_SIGN_IDENTITY`. `ios-simulator` creates an ad-hoc signed
arm64 simulator bundle under `build/ios-simulator/Score.app`. UIKit is only the
lifecycle/device host—the product UI and audio instrument remain shared Zig.
`dev-ios` builds and launches the Debug simulator app, then watches the Metal
source. A changed shader is compiled into a candidate pipeline without pausing
the render loop; invalid source retains the last-good pipeline and live
Zig/Flecs state, while a valid edit swaps at a main-thread frame boundary.

For an automated Simulator audio-path check, launch the installed Debug app
with `SIMCTL_CHILD_SCORE_IOS_ACCEPTANCE=1`. This opt-in test starts transport
after journal restoration and logs the AVAudioEngine running state, received
event count, CC64 sustain count/value, rendered nonzero-sample count, and peak
after six seconds. Normal launches never autoplay and skip the realtime
diagnostic counters entirely.

## Performance controller

`CONTROLLER` opens an independent, GPU-rendered performance surface shared by
macOS and iPadOS. Its 4×4 square pads are true multitouch controls; the Pads,
Clips, and Actions banks send musical notes, launch a 4×4 track/scene matrix,
or execute 16 mapped actions. Eight additional squares provide stop, play,
record, loop, click, undo, redo, and save. Score, sampler, and practice state
remain untouched when entering or leaving this view.

The `USER` bank is a persistent custom surface. Press `EDIT`, tap a control,
then use the three inspector pages to choose Pad, Button, Toggle, vertical or
horizontal Fader, Encoder, XY surface, or Label; choose a 1x1, 2x1, 1x2, or
2x2 span; and configure Note, Drum, CC, Clip, or Action routing, message
numbers, MIDI channel/clip track, behavior, starting value, and color. `DONE`
returns the surface to performance input. `GRID -/+` changes density from 4x4
through 6x6: zooming out reveals up to 24 controls and leaves packing room for
expanded cells instead of merely magnifying the same layout. Edit mode
never emits a musical/control message, so selecting a mapping cannot trigger a
DAW action. Native preferences are stored independently at
`~/Library/Application Support/Score/controller-preferences.bin`; iPadOS keeps
the same versioned mapping blob in application preferences. Version-1 16-pad
preferences migrate automatically. These
mappings never modify a score, MusicXML document, or captured performance.

Pads can control any instrument hosted by the receiving DAW—drum rack, piano,
guitar sampler, synth, or another plug-in—because the selected/armed DAW track
owns the sound. **MIDI is the default controller protocol.** MIDI mode publishes a device-qualified virtual CoreMIDI source
(`Score Controller — Mac` or `Score Controller — <device> [<id>]`) and also
sends to connected MIDI destinations. A second native process receives a
numeric suffix rather than colliding with the first endpoint. On iPadOS it
prefers the direct USB IDAM destination exposed by Audio MIDI Setup. Network
MIDI remains available only when no direct destination is present, preventing
the same strike from arriving twice when both transports are connected. See
[`IPAD_USB_MIDI_SETUP.md`](IPAD_USB_MIDI_SETUP.md) for the verified physical
device and Bitwig setup.
OSC mode sends directly to a configured UDP host and defaults to port 8000.
For the native host, override `127.0.0.1:8000` with `SCORE_OSC_HOST` and
`SCORE_OSC_PORT`.

For Bitwig, the maintained route is the community
[DrivenByMoss Open Sound Control extension](https://github.com/git-moss/DrivenByMoss-Documentation/blob/master/Generic-Tools-Protocols/Open-Sound-Control-%28OSC%29.md): add its **Open Sound Control** controller, then enter the Mac's IP/hostname and receive port in Score's `SETUP` panel. The Pads bank sends DrivenByMoss virtual-keyboard note messages, Clips sends track/scene launch messages, Actions sends its 1…20 action slots, and transport uses the documented global commands. Bitwig also supports ordinary MIDI controllers through its
[generic MIDI controller workflow](https://www.bitwig.com/userguide/latest/midi_controllers/), so selecting `Score Controller` as the input is the extension-free route.
To map a custom CC/note to a Bitwig parameter, finish editing in Score, open
Bitwig's Mapping Panel, select the target parameter, then press the pad. This
is DAW MIDI Learn: Score defines the message the pad sends, while Bitwig owns
the link from that message to its instrument, effect, mixer, or command.

For local integration and debugging, `tools/bitwig-score-bridge` builds a
Bitwig controller extension that decodes Score's OSC vocabulary and exposes 16
independent `Score OSC` note inputs. Controllers are identified by sender
IP/port, so matching notes from multiple Macs/iPads keep separate note-off,
channel, aftertouch, and CC state. Once all 16 slots are occupied the bridge
logs and rejects another source rather than sharing a slot. See the bridge
README for its build/install command and probe-log path.
Debug builds also install `score-devctl bitwig-bootstrap`, a headless CoreMIDI
endpoint used only to keep those Bitwig note inputs recordable. It has no app
window and carries no controller data, so opening or quitting any Score app
instance cannot disable the other controllers.

The velocity button cycles five explicit modes: Fixed, Dynamic finger impact,
Y Position, Diagonal Position, and Pencil Force. The adjacent button cycles
Soft/Balanced/Hard response curves, or fixed-velocity presets while Fixed is
selected. Dynamic uses UIKit's approximate finger contact radius as a
calibrated impact signal; it is never labelled physical pressure. Y Position
maps vertical pad position to the configured 15...127 range. Diagonal Position
projects the touch from bottom-left (soft) to top-right (loud), making
horizontal placement useful without losing the predictable spatial control of
Y Position. Pencil Force waits up to the first 6 ms high-rate force refresh
before note-on, so a drum sampler receives the refined velocity layer rather
than relying on aftertouch, then streams subsequent force as polyphonic
aftertouch. Finger input in Pencil mode uses the explicit fixed fallback. After
the first strike, the response button includes the latest emitted `VEL 1..127`,
making light/firm Pencil calibration visible as well as audible. Octave
controls retain the same DAW routing.

In a hot-reload Debug session, the surface can be exercised without restarting:

```sh
zig-out/bin/score-devctl controller open
zig-out/bin/score-devctl controller protocol osc
zig-out/bin/score-devctl controller bank pads
zig-out/bin/score-devctl controller bank user
zig-out/bin/score-devctl controller sensitivity dynamic
zig-out/bin/score-devctl controller sensitivity diagonal
zig-out/bin/score-devctl controller curve balanced
zig-out/bin/score-devctl controller density medium
zig-out/bin/score-devctl controller edit on
zig-out/bin/score-devctl controller tap 1
zig-out/bin/score-devctl controller state
```

## Controls

- Space or the center transport button: play/pause with count-in
- `-` / `+`: tempo down/up; the GPU buttons do the same. Click the displayed
  tempo to type a value. The note value is explicit (`1/4 = 147 BPM`, for
  example), while playback/MIDI use the equivalent quarter-note rate.
- Loop: isolate/toggle the measure containing the cursor; Click: toggle the metronome
- Page Up / Page Down, Left / Right in Read mode, or scroll: advance the score
- `M` or the view button: switch between paged and continuous-system views
- In continuous mode, wheel/trackpad or drag the score in Read/Practice for
  smooth vertical pan; page keys remain available for whole-system jumps
- `[` / `]` or the GPU minus/plus controls: zoom the score between 45% and 105%;
  zoom also reflows complete authored measures so zooming out actually reveals
  more measures and complete systems on the same paper sheet
- `F` or Focus: dedicate the window to the score and transport; the piano,
  library, tool rail, and coach return when focus mode is exited
- Read: select a note; Edit: insert a note
- In Edit mode with pedal guidance visible, click a `UC`, `SOST`, or `SUST`
  baseline to add a pressure point, drag the point in beat/value space, add a
  second point to close a range, and press Delete to remove the selected point.
  Pedal and note edits share the same Command/Ctrl-Z and Command/Ctrl-Y history;
  mouse, touch, and pen all use the same GPU hit map.
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
- Part button or `P`: move to the next imported instrumental part when a score
  contains more than one. The displayed/practiced part changes without muting
  other parts in complete-score playback or removing them from exchange export.
  MusicXML part names and General MIDI programs round-trip, and the GPU selector
  shows the imported part name instead of flattening an ensemble into "Piano."
- MusicXML slur numbers 1...8 remain independent through import, portable
  `.score` v17 persistence, GPU engraving, and export. Nested phrases pair with
  their own stops and use span-derived optical lanes across system/page breaks:
  containing phrases sit outside their contained phrases, while interleaved
  spans receive deterministic clearance instead of crossing because of their
  arbitrary MusicXML identifier.
- Dynamic markings use collision-aware optical lanes: duplicate markings on a
  simultaneous chord are coalesced, while cross-staff notes, stems, beams, and
  articulations make the expression move to the nearest clear lane.
- Concurrent crescendo/diminuendo wedges use interval-partitioned optical
  lanes per part, staff, and placement side. Overlapping wedges remain visibly
  separate at maximum opening, while unrelated staff/side groups reuse their
  closest conventional lane; the bounded resolver allocates nothing per frame.
- Simultaneous MusicXML voices retain independent rhythm while sharing a
  professional visual resolver: compatible unisons share a head, conflicting
  unisons/seconds separate horizontally with opposing stems, rests split into
  clear upper/lower lanes, and accidentals use collision-free columns. Beams
  and spanners follow those same resolved note positions.
- Tuplet brackets include rests, follow upper/lower voice lanes, clear beamed
  passages, and continue across responsive system or page boundaries instead
  of disappearing at a reflow break.
- Beam engraving derives all visual levels from rhythmic duration: shared
  eighth-through-sixty-fourth beams remain continuous, while an unshared level
  becomes one deterministic inward hook. Mixed beam groups retain their slope
  and resolved upper/lower voice direction. If responsive reflow cuts through
  an authored beam group, the outgoing and incoming edge notes receive their
  proper duration flags so neither side becomes an unreadable stemless note.
- Common MusicXML ornaments and arpeggiation remain semantic: trills, turns,
  inverted turns, both mordent forms, and up/down arpeggiation survive native
  persistence and export/re-import. Bravura SMuFL glyphs render through the
  same MTSDF GPU path, with ornament and accidental-aware chord clearance.
- Simple MusicXML forward/backward repeat barlines and authored pass counts
  persist, engrave on the GPU, export/re-import, and control native playback.
  A repeat at the final barline keeps the unused fraction of the audio frame,
  so it does not add a timing gap; score pedal state is restored at the return.
  Standard MIDI export unfolds the authored pass count and duplicates tempo
  changes plus three-pedal automation at their performed positions.
  Numbered/ranged alternate endings retain their start, stop, or discontinue
  brackets and pass masks through `.score`, MusicXML, and MXL. The GPU labels
  each volta above the score, native playback skips ineligible endings on later
  passes, and Standard MIDI unfolds the same route. Arbitrarily nested repeat
  graphs remain a later professional-notation gate.
- The offline Score library includes an original CC0 `Flowing 6/4 Piano Lab`.
  Its six progressive sections practice broad 6/4 pulse, two-hand balance,
  close voice leading, off-beat independence, clean harmonic pedal changes,
  and long phrase shaping. Brief reasons are authored as standard MusicXML
  directions in a separate coaching part, while the grand staff retains chord
  symbols, dynamics, fingerings, performed velocities, and pedal semantics.

## Offline reference-audio analysis

Score-facing offline operations are deliberately consolidated in Zig. Use the
single workbench for semantic inspection, candidate transformation, and direct
comparison with retained pitch-event CSV evidence:

```sh
zig build score-workbench -- inspect authorized-score.mxl --measure 12
zig build score-workbench -- evidence authorized-score.mxl \
  --csv guitar_basic_pitch.csv --csv piano_basic_pitch.csv \
  --start-beat 0 --end-beat 42 --quarter-bpm 147
zig build score-workbench -- audit-measures authorized-score.mxl analysis.json \
  --anchors reviewed-measure-windows.json --output measure-review.json
```

`audit-measures` distributes score frames only inside explicit reviewed measure
windows, excludes vocal-guide cues from the piano comparison, and emits
pitch-class, primary-bass, alternate-low-register, RMS, hand-count, and
priority evidence for every current measure. It distinguishes real instrument
attacks from tie continuations and records audible-frame coverage, so one late
transient cannot falsely condemn an otherwise silent release-only bar.
Candidate pitches therefore
cannot make repeated sections jump to a more favorable place in the recording.
Every result remains `REVIEW_REQUIRED` until a musician confirms it.

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
