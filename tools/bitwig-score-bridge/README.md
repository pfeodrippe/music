# Score OSC Bridge + Probe

Development-only Bitwig controller extension for testing Score's iPad/macOS
controller surface against a real Bitwig note input. Bitwig owns the extension
lifecycle in Java; the Score OSC vocabulary is decoded in Clojure.

It listens on UDP port `8000`, exposes 16 `Score OSC 1…16` note inputs, and
keys each active controller by its real UDP source address and port. Note,
aftertouch, CC, and held-note state therefore remain independent even when two
controllers send the same pitch and MIDI channel at the same time. If all 16
slots are occupied, a new source is explicitly rejected and logged; slots are
never wrapped or shared. Every received message is also flushed to:

`~/Library/Application Support/Score/bitwig-score-bridge.log`

Build and install:

```sh
cd tools/bitwig-score-bridge
clojure -M:test
mvn package
mkdir -p "$HOME/Documents/Bitwig Studio/Extensions"
cp target/ScoreBridge.bwextension "$HOME/Documents/Bitwig Studio/Extensions/"
```

Start the existing Zig development controller in headless bootstrap mode before
Bitwig (or before rescanning its Controllers settings):

```sh
cd ../..
zig build
zig-out/bin/score-devctl bitwig-bootstrap
```

This process owns only the stable `Score Bridge Bootstrap` CoreMIDI endpoint;
it creates no app window and carries no performance messages. Bitwig uses that
port to keep its recordable `NoteInput` objects alive. Native Score, iPads, and
other controller instances remain independent OSC clients and can be opened or
closed without taking the bridge down.

In Bitwig, add **Score / Score OSC Bridge + Probe**. During local development,
the bridge auto-detects the headless endpoint named `Score Bridge Bootstrap`.
In Score on each iPad or Mac, select OSC, open Setup, and enter the Bitwig Mac's
address and port `8000`. Each app instance may use the same destination; its
own persistent UDP source port is what gives it a separate Bitwig input slot.
