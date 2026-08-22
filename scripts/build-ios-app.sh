#!/bin/sh
set -eu

score_ios_variant="${1:-device}"
if [ "$score_ios_variant" = "simulator" ]; then
    score_ios_sdk_name="iphonesimulator"
    score_ios_target="arm64-apple-ios17.0-simulator"
    score_ios_build="build/ios-simulator"
    score_ios_sdk=$(xcrun --sdk "$score_ios_sdk_name" --show-sdk-path)
    zig build ios-core \
        -Dios-internal=true \
        -Dios-simulator=true \
        -Doptimize=ReleaseFast \
        --sysroot "$score_ios_sdk" \
        --prefix "$score_ios_build/zig-out"
    score_ios_core="$score_ios_build/zig-out/lib/libscore-ios-core.a"
else
    score_ios_sdk_name="iphoneos"
    score_ios_target="arm64-apple-ios17.0"
    score_ios_build="build/ios"
    score_ios_sdk=$(xcrun --sdk "$score_ios_sdk_name" --show-sdk-path)
    score_ios_core="zig-out/lib/libscore-ios-core.a"
fi
score_ios_app="$score_ios_build/Score.app"

mkdir -p "$score_ios_app"
xcrun --sdk "$score_ios_sdk_name" metal \
    -c src/platform/apple/ios/ScoreShaders.metal \
    -o "$score_ios_build/ScoreShaders.air"
xcrun --sdk "$score_ios_sdk_name" metallib \
    "$score_ios_build/ScoreShaders.air" \
    -o "$score_ios_app/ScoreShaders.metallib"

cp src/platform/apple/ios/Info.plist "$score_ios_app/Info.plist"
cp src/platform/web/icons/score-icon-1024.png "$score_ios_app/AppIcon.png"
plutil -lint "$score_ios_app/Info.plist"

xcrun --sdk "$score_ios_sdk_name" swiftc \
    -sdk "$score_ios_sdk" \
    -target "$score_ios_target" \
    -O \
    -parse-as-library \
    -module-name Score \
    -import-objc-header src/platform/apple/score_ios.h \
    src/platform/apple/ios/ScoreApp.swift \
    src/platform/apple/ios/ScoreMetalView.swift \
    src/platform/apple/ios/ScoreServices.swift \
    "$score_ios_core" \
    -framework UIKit \
    -framework Metal \
    -framework QuartzCore \
    -framework AVFoundation \
    -framework CoreMIDI \
    -framework UniformTypeIdentifiers \
    -o "$score_ios_app/Score"

if [ "$score_ios_variant" = "simulator" ]; then
    codesign --force --sign - "$score_ios_app" >/dev/null
    echo "$score_ios_app (simulator)"
elif [ -n "${SCORE_IOS_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SCORE_IOS_SIGN_IDENTITY" --entitlements src/platform/apple/ios/Score.entitlements "$score_ios_app"
    echo "signed $score_ios_app"
else
    echo "$score_ios_app (unsigned; set SCORE_IOS_SIGN_IDENTITY for device installation)"
fi
