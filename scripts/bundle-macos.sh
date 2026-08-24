#!/bin/sh
set -eu

bundle="zig-out/Score.app"
contents="$bundle/Contents"
resources="$contents/Resources"
frameworks="$contents/Frameworks"
icon_source="src/platform/web/icons/score-icon-1024.png"
icon_workspace="$(mktemp -d)"
trap 'rm -rf "$icon_workspace"' EXIT INT TERM
iconset="$icon_workspace/Score.iconset"

mkdir -p "$contents/MacOS" "$resources" "$frameworks" "$iconset"
cp zig-out/bin/score "$contents/MacOS/score"
cp zig-out/lib/libsfizz.dylib "$frameworks/libsfizz.dylib"
cp packaging/macos/Info.plist "$contents/Info.plist"
rm -rf "$resources/Legal"
mkdir -p "$resources/Legal"
cp -R legal/third-party-notices "$resources/Legal/"
cp -R legal/content-licenses "$resources/Legal/"
mkdir -p "$resources/Legal/dependency-licenses"
cp vendor/flecs/LICENSE "$resources/Legal/dependency-licenses/Flecs-LICENSE.txt"
cp vendor/sfizz/LICENSE "$resources/Legal/dependency-licenses/sfizz-LICENSE.txt"
cp vendor/sfizz/AUTHORS.md "$resources/Legal/dependency-licenses/sfizz-AUTHORS.md"
cp zig-pkg/zglfw-*/LICENSE "$resources/Legal/dependency-licenses/zglfw-LICENSE.txt"
cp zig-pkg/zgpu-*/LICENSE "$resources/Legal/dependency-licenses/zgpu-LICENSE.txt"
cp zig-pkg/zpool-*/LICENSE "$resources/Legal/dependency-licenses/zpool-LICENSE.txt"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/Score.icns"
codesign --force --deep --sign - "$bundle" >/dev/null
touch "$bundle"
echo "$bundle"
