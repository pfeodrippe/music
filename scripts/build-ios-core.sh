#!/bin/sh
set -eu

score_ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
exec zig build ios-core \
    -Dios-internal=true \
    -Doptimize=ReleaseFast \
    --sysroot "$score_ios_sdk"
