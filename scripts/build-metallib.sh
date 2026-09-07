#!/bin/bash
# WHAT: Compile Frigate's vendored MLX Metal shaders into mlx.metallib.
# IN:   [debug|release] (default debug). FRIGATE_DIR overrides Frigate path.
# OUT:  .build/$CONFIG/mlx.metallib — MLX's first search rung (binary dir).
# PIN:  `swift build` has no Metal step. Without this, GPU load fails at
#       runtime. Skip when no .metal is newer than the library.
#
#   ./scripts/build-metallib.sh [debug|release]
#
# Callers: Mary's LocalStackManager after `swift build -c release`.
#
set -e

CONFIG="${1:-debug}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRIGATE_DIR="${FRIGATE_DIR:-$REPO_ROOT/../Frigate}"
MLX_METAL_DIR="$FRIGATE_DIR/Sources/Cmlx/mlx-generated/metal"
BINARY_DIR="$REPO_ROOT/.build/$CONFIG"
METALLIB_OUT="$BINARY_DIR/mlx.metallib"

if [ ! -d "$MLX_METAL_DIR" ]; then
    echo "build-metallib: no MLX metal shaders at $MLX_METAL_DIR"
    echo "  Set FRIGATE_DIR, or run 'swift build' first to resolve dependencies."
    exit 1
fi

mkdir -p "$BINARY_DIR"

# Skip when current — three callers; ~50 files per compile.
if [ -f "$METALLIB_OUT" ] \
   && [ -z "$(find "$MLX_METAL_DIR" -name '*.metal' -newer "$METALLIB_OUT" -print -quit)" ]; then
    echo "build-metallib: $METALLIB_OUT is current"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "build-metallib: compiling shaders from $MLX_METAL_DIR"

AIR_FILES=()
while IFS= read -r -d '' metal_file; do
    base="$(basename "$metal_file" .metal)"
    air_file="$TMP_DIR/$base.air"
    xcrun -sdk macosx metal \
        -x metal \
        -fno-fast-math \
        -Wno-c++17-extensions \
        -Wno-c++20-extensions \
        -mmacosx-version-min=14.0 \
        -I "$MLX_METAL_DIR" \
        -c "$metal_file" \
        -o "$air_file"
    AIR_FILES+=("$air_file")
done < <(find "$MLX_METAL_DIR" -name "*.metal" -print0)

if [ ${#AIR_FILES[@]} -eq 0 ]; then
    echo "build-metallib: found no .metal files to compile — refusing to write an empty library"
    exit 1
fi

echo "build-metallib: linking ${#AIR_FILES[@]} shaders"
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$METALLIB_OUT"
echo "build-metallib: wrote $METALLIB_OUT"
