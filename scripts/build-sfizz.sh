#!/bin/sh
set -eu

build_dir=".zig-cache/sfizz-build"
output_dir="zig-out/lib"
output_library="$output_dir/libsfizz.dylib"
revision_file="$build_dir/score-sfizz-revision"
sfizz_revision=$(git -C vendor/sfizz rev-parse HEAD)

if [ -f "$output_library" ] && [ -f "$revision_file" ] && [ "$(sed -n '1p' "$revision_file")" = "$sfizz_revision" ]; then
    exit 0
fi

cmake \
    -S vendor/sfizz \
    -B "$build_dir" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DSFIZZ_RENDER=OFF \
    -DSFIZZ_JACK=OFF \
    -DSFIZZ_SHARED=ON \
    -DSFIZZ_TESTS=OFF \
    -DSFIZZ_DEMOS=OFF \
    -DSFIZZ_BENCHMARKS=OFF \
    -DSFIZZ_DEVTOOLS=OFF \
    -DENABLE_LTO=OFF
cmake --build "$build_dir" --target libsfizz.dylib -j 8

mkdir -p "$output_dir"
cp -L "$build_dir/library/lib/libsfizz.dylib" "$output_dir/libsfizz.dylib"
git -C vendor/sfizz rev-parse HEAD > "$revision_file"
