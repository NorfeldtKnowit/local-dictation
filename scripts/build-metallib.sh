#!/usr/bin/env bash
# Compiles MLX's Metal shaders into .build/mlx.metallib.
#
# Plain `swift build` CANNOT compile .metal sources — mlx-swift's own README
# says so ("SwiftPM (command line) cannot build the Metal shaders, xcodebuild
# can"). Without the metallib, MLX aborts at first GPU use with "Failed to
# load the default metallib". This script runs the one xcodebuild pass that
# produces it, then caches the artifact where the rest of the tooling looks:
#
#   .build/mlx.metallib                      <- build-app.sh copies from here
#   .build/{debug,release}/mlx.metallib      <- `swift run` / release binary
#   .build/debug/*.xctest/Contents/MacOS/    <- the MLX smoke test
#
# The metallib is version-locked to the mlx-swift checkout (kernel names/ABI
# must match the C++ that calls them): RE-RUN THIS after bumping mlx-swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .build/mlx.metallib ] || [ "${1:-}" = "--force" ]; then
  echo "Compiling MLX Metal shaders via xcodebuild (several minutes)…"
  xcodebuild build -scheme LocalDictation -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/xcodebuild -quiet
  LIB="$(find .build/xcodebuild/Build/Products -name "default.metallib" -path "*Cmlx*" | head -1)"
  if [ -z "$LIB" ]; then
    echo "default.metallib not found under .build/xcodebuild/Build/Products" >&2
    exit 1
  fi
  cp "$LIB" .build/mlx.metallib
fi

# Colocate next to every binary that may exercise MLX (loader path #1:
# mlx.metallib in the executable's own directory).
for dir in .build/debug .build/release; do
  [ -d "$dir" ] && cp .build/mlx.metallib "$dir/mlx.metallib"
done
for xctest in .build/debug/*.xctest/Contents/MacOS .build/release/*.xctest/Contents/MacOS; do
  [ -d "$xctest" ] && cp .build/mlx.metallib "$xctest/mlx.metallib"
done

echo "mlx.metallib ready at .build/mlx.metallib (and colocated with binaries)"
