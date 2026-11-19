#!/bin/bash
# Собирает AutoVPN.app в ./dist (ad-hoc подпись).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/AutoVPN.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.alsh.autovpn</string>
  <key>CFBundleName</key><string>AutoVPN</string>
  <key>CFBundleDisplayName</key><string>AutoVPN</string>
  <key>CFBundleExecutable</key><string>AutoVPN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST

cp .build/release/AutoVPN "$APP/Contents/MacOS/AutoVPN"
codesign --force -s - "$APP"
echo "OK: $APP"
