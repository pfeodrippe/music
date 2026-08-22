#!/bin/sh
set -eu

zig build

watch_systems() {
    while true; do
        find src/systems src/hot_reload src/core/model.zig -type f | sort | entr -d sh -c 'zig build systems || true'
    done
}

watch_systems &
score_watcher_pid=$!
trap 'kill "$score_watcher_pid" 2>/dev/null || true' EXIT INT TERM

./zig-out/bin/score

