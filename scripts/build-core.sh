#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# Builds the Rust FFI staticlib, regenerates the Swift bindings, and
# assembles build/MarginsFFI.xcframework — the binaryTarget that
# Package.swift links (replacing the old .unsafeFlags link of
# target/release/libmargins_ffi.a, which cannot carry iOS architectures).
#
# The macOS slice is always (re)built. IOS_SLICES=1 (see
# scripts/build-xcframework.sh) additionally builds the iOS device and
# simulator slices.
#
# UNIVERSAL=1 lipo's aarch64-apple-darwin + x86_64-apple-darwin into a
# single macos slice so the Swift package can produce a universal binary
# (make mac-app-universal).
universal=${UNIVERSAL:-0}
ios_slices=${IOS_SLICES:-0}

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
c_include="$root/apple/Sources/margins_ffiFFI/include"
swift_src="$root/apple/Sources/MarginsCore/Generated"
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

# --- xcframework assembly -------------------------------------------------
# Bare static-library slices (no .framework bundles): each carries the
# archive plus the UniFFI header/module map so the framework is
# self-contained for Xcode as well as SwiftPM. Info.plist is regenerated
# from the slice directories present on disk, so refreshing the mac slice
# never destroys previously built iOS slices.
xcframework="$root/build/MarginsFFI.xcframework"
header="$c_include/margins_ffiFFI.h"
modulemap="$c_include/module.modulemap"

if [ "$universal" = "1" ]; then
  for arch in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --release -p margins-ffi --target "$arch"
  done
  lipo -create \
    -output "$root/target/release/libmargins_ffi.a" \
    "$root/target/aarch64-apple-darwin/release/libmargins_ffi.a" \
    "$root/target/x86_64-apple-darwin/release/libmargins_ffi.a"
  mac_slice="macos-arm64_x86_64"
else
  case "$(uname -m)" in
    arm64) mac_slice="macos-arm64" ;;
    *) mac_slice="macos-x86_64" ;;
  esac
fi

rm -rf "$xcframework"/macos-*
write_slice() {
  # $1 slice dir name, $2 static archive
  mkdir -p "$xcframework/$1/Headers"
  cp "$2" "$xcframework/$1/libmargins_ffi.a"
  cp "$header" "$xcframework/$1/Headers/margins_ffiFFI.h"
  cp "$modulemap" "$xcframework/$1/Headers/module.modulemap"
}
write_slice "$mac_slice" "$root/target/release/libmargins_ffi.a"

if [ "$ios_slices" = "1" ]; then
  cargo build --release -p margins-ffi --target aarch64-apple-ios
  write_slice "ios-arm64" \
    "$root/target/aarch64-apple-ios/release/libmargins_ffi.a"

  rm -rf "$xcframework"/ios-*-simulator
  # x86_64-apple-ios-sim is absent from some Rust toolchains (e.g. 1.96);
  # an arm64-only simulator slice is fine on Apple Silicon.
  if rustup target list --installed | grep -q '^x86_64-apple-ios-sim$'; then
    cargo build --release -p margins-ffi --target x86_64-apple-ios-sim
    lipo -create \
      -output "$root/target/aarch64-apple-ios-sim/release/libmargins_ffi.a" \
      "$root/target/aarch64-apple-ios-sim/release/libmargins_ffi.a" \
      "$root/target/x86_64-apple-ios-sim/release/libmargins_ffi.a"
    write_slice "ios-arm64_x86_64-simulator" \
      "$root/target/aarch64-apple-ios-sim/release/libmargins_ffi.a"
  else
    cargo build --release -p margins-ffi --target aarch64-apple-ios-sim
    write_slice "ios-arm64-simulator" \
      "$root/target/aarch64-apple-ios-sim/release/libmargins_ffi.a"
  fi
fi

# Info.plist, derived from the slices present.
slice_entry() {
  case "$1" in
    macos-arm64_x86_64)          platform=macos; arches="arm64 x86_64"; variant="" ;;
    macos-arm64 | macos-x86_64)  platform=macos; arches="${1#macos-}";  variant="" ;;
    ios-arm64_x86_64-simulator)  platform=ios;   arches="arm64 x86_64"; variant=simulator ;;
    ios-arm64-simulator)         platform=ios;   arches="arm64";        variant=simulator ;;
    ios-arm64)                   platform=ios;   arches="arm64";        variant="" ;;
    *) return 0 ;;
  esac
  cat <<EOF
        <dict>
            <key>LibraryIdentifier</key>
            <string>$1</string>
            <key>LibraryPath</key>
            <string>libmargins_ffi.a</string>
            <key>SupportedArchitectures</key>
            <array>
$(for a in $arches; do printf '                <string>%s</string>\n' "$a"; done)
            </array>
            <key>SupportedPlatform</key>
            <string>$platform</string>
EOF
  if [ -n "$variant" ]; then
    printf '            <key>SupportedPlatformVariant</key>\n            <string>%s</string>\n' "$variant"
  fi
  printf '        </dict>\n'
}

{
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
EOF
  for dir in $(ls "$xcframework" | sort); do
    [ -d "$xcframework/$dir" ] || continue
    slice_entry "$dir"
  done
  cat <<'EOF'
    </array>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF
} > "$xcframework/Info.plist"

echo "generated Swift bindings under apple/Sources/"
echo "assembled $xcframework ($(ls "$xcframework" | grep -v Info.plist | tr '\n' ' '))"
