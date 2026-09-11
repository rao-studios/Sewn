#!/usr/bin/env bash
# WHAT: Build MLX's mlx.metallib into this package's .build.
# IN:   [debug|release] (default debug). FRIGATE_DIR overrides where Frigate lives.
# PIN:  A DELEGATE, NOT AN IMPLEMENTATION. Frigate owns the .metal sources, so it owns the
#       compile. Five hand-copied versions of this script had drifted apart, and this one
#       pointed at its own copy of the compile logic, which drifted from the others. The one in
#       Thread had already broken outright. The canonical script also installs into .xctest
#       bundles so the MLX-gated test suites can actually run, which none of the copies did.
#
#
#   ./scripts/build-metallib.sh [debug|release]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRIGATE_DIR="${FRIGATE_DIR:-$REPO_ROOT/../Frigate}"
CANONICAL="$FRIGATE_DIR/scripts/build-metallib.sh"

if [ ! -x "$CANONICAL" ]; then
    echo "build-metallib: cannot find $CANONICAL" >&2
    echo "  Set FRIGATE_DIR to your Frigate checkout." >&2
    exit 1
fi

exec "$CANONICAL" "${1:-debug}" --package "$REPO_ROOT"
