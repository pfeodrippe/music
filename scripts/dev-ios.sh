#!/bin/sh
set -eu

score_bundle_id="app.score.practice.ios"
score_shader_source="$(pwd)/src/platform/apple/ios/ScoreShaders.metal"

if ! xcrun simctl list devices booted | grep -q '(Booted)'; then
    printf '%s\n' 'No booted iOS Simulator. Start one from Xcode, then rerun zig build dev-ios.' >&2
    exit 1
fi

SCORE_IOS_DEVELOPMENT=1 sh scripts/build-ios-app.sh simulator
xcrun simctl install booted build/ios-simulator/Score.app
xcrun simctl launch --terminate-running-process booted "$score_bundle_id"

score_data_container=$(xcrun simctl get_app_container booted "$score_bundle_id" data)
score_shader_directory="$score_data_container/Library/Application Support/Score"
score_shader_target="$score_shader_directory/ScoreShaders.metal"
mkdir -p "$score_shader_directory"
cp "$score_shader_source" "$score_shader_target"

export SCORE_IOS_SHADER_SOURCE="$score_shader_source"
export SCORE_IOS_SHADER_TARGET="$score_shader_target"
printf 'Watching %s\n' "$score_shader_source"
printf 'Last-good shader override: %s\n' "$score_shader_target"
find "$score_shader_source" | entr -np sh -c 'cp "$SCORE_IOS_SHADER_SOURCE" "$SCORE_IOS_SHADER_TARGET"'
