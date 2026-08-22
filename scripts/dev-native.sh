#!/bin/sh
set -eu

zig build

score_project_root=$(pwd)
export SCORE_HOT_RELOAD_PLUGIN="$score_project_root/zig-out/lib/libscore-systems.dylib"

watch_runtime_module() {
    while true; do
        find \
            src/systems \
            src/hot_reload \
            src/core/ui.zig \
            src/core/model.zig \
            src/core/annotation.zig \
            src/render/packet.zig \
            src/render/glyph_atlas.zig \
            -type f | sort | entr -d sh -c 'zig build systems || true'
    done
}

watch_runtime_module &
score_runtime_watcher_pid=$!
trap 'kill "$score_runtime_watcher_pid" 2>/dev/null || true' EXIT INT TERM

./zig-out/bin/score
