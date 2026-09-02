#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

swift build -c release --package-path macos

bin="macos/.build/release/Margins"
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

resources_bundle="macos/.build/release/Margins_Margins.bundle"
if [ -d "$resources_bundle" ]; then
  cp -R "$resources_bundle" "$app/Contents/Resources/"
else
  echo "warning: SwiftPM resource bundle not found at $resources_bundle" >&2
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Margins</string>
    <key>CFBundleIconFile</key>
    <string>Margins</string>
    <key>CFBundleIdentifier</key>
    <string>app.margins.Margins</string>
    <key>CFBundleName</key>
    <string>Margins</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "assembled $app"
