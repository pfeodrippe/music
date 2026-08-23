# Tool policy

This directory contains only thin platform build, packaging, development, and
authorized local-capture wrappers. It must not grow independent score-analysis
or MusicXML transformation scripts.

Score inspection, transformation, and recording-event comparison are
subcommands of the single Zig executable in `src/tools/score_workbench.zig`:

```sh
zig build score-workbench -- inspect SCORE.mxl
zig build score-workbench -- pattern-fragment TEMPLATE.mxl PATTERN.txt FRAGMENT.mxl --pedal-value 72
zig build score-workbench -- splice-opening TARGET.mxl FRAGMENT.mxl OUTPUT.mxl --target-end-beat N --repeat-count N
zig build score-workbench -- opening-performance INPUT.mxl OUTPUT.mxl
zig build score-workbench -- enrich-opening TARGET.mxl FRAGMENT.mxl OUTPUT.mxl
zig build score-workbench -- evidence SCORE.mxl --csv EVENTS.csv
zig build score-workbench -- evidence SCORE.mxl --csv EVENTS.csv --anchors ANCHORS.json --output REPORT.json --detail-measure N
zig build score-workbench -- audio-evidence INPUT.wav --score SCORE.mxl
zig build score-workbench -- shape-performance INPUT.mxl AUDIO.wav OUTPUT.mxl --start-beat N --end-beat N
zig build score-workbench -- compare-performance REFERENCE.wav CANDIDATE.wav --output REPORT.json
zig build score-workbench -- rebase-anchors SOURCE.mxl SOURCE-ANCHORS.json TARGET.mxl OUTPUT.json --source-cut-beat N --target-insert-end-beat N
zig build score-workbench -- shape-performance INPUT.mxl AUDIO.wav OUTPUT.mxl --start-beat N --end-beat N --anchors ANCHORS.json
zig build score-workbench -- compare-performance REFERENCE.wav CANDIDATE.wav --score SCORE.mxl --anchors ANCHORS.json --output REPORT.json
zig build score-workbench -- enrich-evidence TARGET.mxl OUTPUT.mxl --anchors REVIEW.json --csv EVENTS.csv --start-beat N --end-beat N
zig build score-workbench -- playability SCORE.mxl
zig build score-workbench -- dedupe INPUT.mxl OUTPUT.mxl
zig build score-workbench -- revoice INPUT.mxl OUTPUT.mxl --beat N --pitch MIDI --from-staff N --to-staff N
zig build score-workbench -- retune INPUT.mxl OUTPUT.mxl --replace BEAT:STAFF:FROM_MIDI:TO_MIDI
zig build score-workbench -- pedalize INPUT.mxl OUTPUT.mxl --preserve-existing
zig build score-workbench -- pedalize INPUT.mxl OUTPUT.mxl --preserve-existing --max-refresh-beats 12 --normalize-restarts
zig build score-workbench -- pedalize INPUT.mxl OUTPUT.mxl --preserve-existing --harmony-refresh-min-beats 4 --normalize-restarts
zig build score-workbench -- pedalize INPUT.mxl OUTPUT.mxl --harmonic-midpoint
zig build && ./zig-out/bin/score-sampler-workbench render-score SCORE.mxl OUTPUT.wav --start-beat N --end-beat N --detail 64:64:64:64
```

The only other Zig tool sources are `dev_control.zig` for the Debug control
socket and `sampler_workbench.zig` for `render`/`verify` sampler gates. There
are three tool source files total; new score transforms belong in the workbench.

The former Python pipeline was removed from the repository on 2026-08-23. Its
last local copies are recoverable in the ignored
`local-content/tool-archive/python-retired-20260823/` directory while remaining
functionality is either folded into the Zig workbench or deliberately retired.
Generated scores, reports, captures, and licensed/private evidence stay under
ignored `local-content/`, `captures/`, `output/`, or `tmp/` paths.
