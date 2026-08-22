#!/bin/sh
set -eu

zig build web
python3 -m http.server 8080 --directory build/web &
score_web_server=$!
find src scripts -type f \( -name '*.zig' -o -name '*.cpp' -o -name '*.js' -o -name '*.html' -o -name '*.wgsl' \) | entr -r sh -c 'zig build web' &
score_web_watcher=$!

trap 'kill "$score_web_server" "$score_web_watcher" 2>/dev/null || true' EXIT INT TERM
wait "$score_web_watcher"
