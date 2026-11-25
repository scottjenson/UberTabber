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
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>UberTabber listens only while its list is open, so you can say the name of a window or tab.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Speech is recognized on this Mac to highlight the window or tab you name.</string>
</dict>
</plist>
EOF
codesign --force --sign - -r='designated => identifier "org.jenson.UberTabber"' "$APP"

# Wait for the old copy to exit, then give Launch Services a moment to notice.
pkill -x UberTabber && while pgrep -x UberTabber >/dev/null; do sleep 0.1; done && sleep 1
open "$APP"
echo "Launched $PWD/$APP"
