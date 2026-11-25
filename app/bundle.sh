#!/bin/zsh
# Builds UberTabber.app in app/build/ and launches it.
# Signed ad hoc, but with a designated requirement of just the bundle identifier,
# so the Accessibility permission survives rebuilds.
set -e
cd "${0:A:h}"

swift build -c release
APP=build/UberTabber.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/UberTabber "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>org.jenson.UberTabber</string>
  <key>CFBundleName</key><string>UberTabber</string>
  <key>CFBundleExecutable</key><string>UberTabber</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - -r='designated => identifier "org.jenson.UberTabber"' "$APP"

pkill -x UberTabber || true
open "$APP"
echo "Launched $PWD/$APP"
