#!/bin/sh
set -eu

bundle="zig-out/Score.app"
contents="$bundle/Contents"
resources="$contents/Resources"
icon_source="src/platform/web/icons/score-icon-1024.png"
icon_workspace="$(mktemp -d)"
trap 'rm -rf "$icon_workspace"' EXIT INT TERM
iconset="$icon_workspace/Score.iconset"

mkdir -p "$contents/MacOS" "$resources" "$iconset"
cp zig-out/bin/score "$contents/MacOS/score"
cp packaging/macos/Info.plist "$contents/Info.plist"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/Score.icns"
codesign --force --deep --sign - "$bundle" >/dev/null
touch "$bundle"
echo "$bundle"
