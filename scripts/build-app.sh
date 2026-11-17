#!/bin/bash
# Builds build/Ovius.app: the release build, signed for this Mac (ad hoc).
#   scripts/build-app.sh            then open build/Ovius.app, or copy it to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Ovius
bin="$(swift build -c release --show-bin-path)"
version="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"

app="build/Ovius.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Ovius" "$app/Contents/MacOS/Ovius"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ovius</string>
  <key>CFBundleDisplayName</key><string>Ovius</string>
  <key>CFBundleIdentifier</key><string>com.caterpler.ovius</string>
  <key>CFBundleExecutable</key><string>Ovius</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.business</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
