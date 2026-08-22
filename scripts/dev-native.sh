#!/bin/sh
set -eu

zig build

score_project_root=$(pwd)
export SCORE_HOT_RELOAD_PLUGIN="$score_project_root/zig-out/lib/libscore-systems.dylib"
export SCORE_HOT_RELOAD_SHADER="$score_project_root/src/render/shaders/ui.wgsl"

restart_marker=$(mktemp -t score-native-restart.XXXXXX)
score_runtime_watcher_pid=
score_resource_watcher_pid=
score_app_pid=

cleanup() {
    [ -z "$score_runtime_watcher_pid" ] || kill "$score_runtime_watcher_pid" 2>/dev/null || true
    [ -z "$score_resource_watcher_pid" ] || kill "$score_resource_watcher_pid" 2>/dev/null || true
    [ -z "$score_app_pid" ] || kill "$score_app_pid" 2>/dev/null || true
    rm -f "$restart_marker"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

while true; do
    : > "$restart_marker"
    ./zig-out/bin/score "$@" &
    score_app_pid=$!

    find \
        src/systems \
        src/core/ui.zig \
        -type f | sort | entr -np sh -c 'zig build systems || true' &
    score_runtime_watcher_pid=$!

    # Files that define host ABI or persistent GPU resources cannot be swapped
    # independently from the executable. Rebuild and relaunch them together;
    # this prevents a new glyph UV table from sampling an old Metal texture.
    (
        find src/platform/native src/audio src/render src/hot_reload -type f ! -path src/render/shaders/ui.wgsl
        find src/core -type f ! -path src/core/ui.zig
        printf '%s\n' build.zig
    ) | sort | entr -np sh -c "printf restart > '$restart_marker'; kill -TERM '$score_app_pid'" &
    score_resource_watcher_pid=$!

    set +e
    wait "$score_app_pid"
    score_status=$?
    set -e
    score_app_pid=
    kill "$score_runtime_watcher_pid" "$score_resource_watcher_pid" 2>/dev/null || true
    wait "$score_runtime_watcher_pid" "$score_resource_watcher_pid" 2>/dev/null || true
    score_runtime_watcher_pid=
    score_resource_watcher_pid=

    if [ -s "$restart_marker" ]; then
        zig build
        continue
    fi
    exit "$score_status"
done
