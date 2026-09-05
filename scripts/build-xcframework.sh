#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Full FFI xcframework: macOS slice + iOS device/simulator slices, plus the
# regenerated Swift bindings. See scripts/build-core.sh for the pipeline.
IOS_SLICES=1 exec "$root/scripts/build-core.sh"
