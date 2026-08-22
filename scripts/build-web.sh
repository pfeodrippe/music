#!/bin/sh
set -eu

mkdir -p build/web
score_emscripten_cache=$(em-config CACHE)

zig build-exe src/audio/worklet_dsp.zig \
    -target wasm32-freestanding \
    -OReleaseFast \
    -fno-entry \
    -rdynamic \
    -femit-bin=build/web/audio_dsp.wasm

zig build-obj src/wasm_root.zig \
    -target wasm32-emscripten \
    -OReleaseSmall \
    -fno-entry \
    -femit-bin=build/web/score_core.o \
    --sysroot "$score_emscripten_cache/sysroot" \
    -I "$score_emscripten_cache/sysroot/include" \
    -I vendor/flecs/distr \
    -lc

emcc -c vendor/flecs/distr/flecs.c \
    -O2 \
    -std=c99 \
    -DFLECS_CUSTOM_BUILD \
    -DFLECS_SYSTEM \
    -DFLECS_PIPELINE \
    -DFLECS_TIMER \
    -o build/web/flecs.o

(cd src/render/shaders && xxd -i ui.wgsl ../../../build/web/ui_shader.h)

em++ src/platform/web/main.cpp build/web/score_core.o build/web/flecs.o \
    --use-port=emdawnwebgpu \
    -Ibuild/web \
    -O2 \
    -sALLOW_MEMORY_GROWTH=1 \
    -sINITIAL_MEMORY=67108864 \
    -sSTACK_SIZE=4194304 \
    -sNO_EXIT_RUNTIME=1 \
    -sENVIRONMENT=web \
    --pre-js src/platform/web/bootstrap.js \
    --shell-file src/platform/web/shell.html \
    -o build/web/score.html

cp build/web/score.html build/web/index.html
cp src/platform/web/audio-worklet.js build/web/audio-worklet.js
cp src/platform/web/manifest.webmanifest build/web/manifest.webmanifest
cp src/platform/web/service-worker.js build/web/service-worker.js
cp src/platform/web/_headers build/web/_headers
mkdir -p build/web/icons
cp src/platform/web/icons/score-icon-192.png build/web/icons/score-icon-192.png
cp src/platform/web/icons/score-icon-512.png build/web/icons/score-icon-512.png
date +%s > build/web/dev-revision.txt
