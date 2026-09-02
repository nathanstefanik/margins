#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

cargo build --release -p margins-ffi

stage="$root/target/uniffi-out"
rm -rf "$stage"
mkdir -p "$stage"

cargo run -p margins-ffi --bin uniffi-bindgen -- generate --library \
  "$root/target/release/libmargins_ffi.dylib" \
  --language swift \
  --out-dir "$stage"

# SwiftPM layout:
#   Sources/margins_ffiFFI/include/   C target: header + module.modulemap
#   Sources/MarginsCore/Generated/    Swift target: generated bindings
c_include="$root/macos/Sources/margins_ffiFFI/include"
swift_src="$root/macos/Sources/MarginsCore/Generated"
mkdir -p "$c_include" "$swift_src"

mv "$stage/margins_ffiFFI.h" "$c_include/margins_ffiFFI.h"
mv "$stage/margins_ffi.swift" "$swift_src/margins_ffi.swift"

# SwiftPM uses the C target's module name; drop the standalone modulemap's
# `use` lines (those are for Xcode-style module builds, not SwiftPM).
cat > "$c_include/module.modulemap" <<'EOF'
module margins_ffiFFI {
    header "margins_ffiFFI.h"
    export *
}
EOF

rm -rf "$stage"
echo "generated Swift bindings under macos/Sources/"
