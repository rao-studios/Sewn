#!/bin/bash
# WHAT: Run the on-device SinatraHarness tests, the live two-turn test included.
# IN:   SEWN_LOCAL_SINATRA_MODEL to pick the model (default Mistral Small 3.2 4-bit).
# PIN:  The test bundle is code-signed at build time and a metallib copied into it breaks
#       the seal, so it is removed before the build and installed after.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for bundle in .build/out/Products/Debug/*.xctest; do
  [ -d "$bundle" ] || continue
  rm -f "$bundle/Contents/MacOS/mlx.metallib"
  rm -rf "$bundle/Contents/MacOS/Resources"
done
swift build --build-tests
"$ROOT/scripts/build-metallib.sh" debug > /dev/null
SEWN_LOCAL_SINATRA_TESTS=1 swift test --skip-build --filter "LocalSinatra" "$@"
