#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

cargo build --release -p margins-ffi

out="$root/macos/Sources/MarginsCoreFFI/Generated"
mkdir -p "$out"

cargo run -p margins-ffi --bin uniffi-bindgen -- generate --library \
  "$root/target/release/libmargins_ffi.dylib" \
  --language swift \
  --out-dir "$out"
