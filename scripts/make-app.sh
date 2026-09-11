#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

universal=${UNIVERSAL:-0}
if [ "$universal" = "1" ]; then
  build_dir="apple/.build/apple/Products/Release"
else
  build_dir="apple/.build/release"
fi

swift_arch=""
if [ "$universal" = "1" ]; then
  swift_arch="--arch arm64 --arch x86_64"
fi

swift build -c release --package-path apple $swift_arch

bin="$build_dir/Margins"
if [ ! -f "$bin" ]; then
  echo "release binary not found at $bin" >&2
  exit 1
fi

app="$root/build/Margins.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Margins"

icon="$root/scripts/assets/Margins.icns"
if [ -f "$icon" ]; then
  cp "$icon" "$app/Contents/Resources/Margins.icns"
else
  echo "warning: Margins.icns not found at $icon (run scripts/make-icon.swift)" >&2
fi

for bundle in "$build_dir/Margins_Margins.bundle" "$build_dir/Margins_MarginsModel.bundle"; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$app/Contents/Resources/"
    # SwiftPM stamps resource bundles with a CFBundleExecutable that does
    # not exist on disk; the App Store validator rejects that.
    /usr/libexec/PlistBuddy -c "Delete :CFBundleExecutable" \
      "$app/Contents/Resources/$(basename "$bundle")/Contents/Info.plist" 2>/dev/null || true
  else
    echo "warning: expected SwiftPM resource bundle not found at $bundle" >&2
  fi
done

version=$(tr -d '[:space:]' < "$root/apple/VERSION")
if [ -z "$version" ]; then
  echo "could not read version from apple/VERSION" >&2
  exit 1
fi

build_number=${MARGINS_BUILD_NUMBER:-1}

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Margins</string>
    <key>CFBundleIconFile</key>
    <string>Margins</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.nathanstefanik.margins</string>
    <key>CFBundleName</key>
    <string>Margins</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.books</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "assembled $app"
