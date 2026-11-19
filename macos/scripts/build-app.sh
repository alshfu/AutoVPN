#!/bin/bash
# Собирает AutoVPN.app в ./dist (ad-hoc подпись) со встроенным sing-box.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$(dirname "$0")/.."

swift build -c release

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) GOARCH=arm64 ;;
  x86_64) GOARCH=amd64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

SINGBOX_DIR="$(mktemp -d)"
trap 'rm -rf "$SINGBOX_DIR"' EXIT
"$ROOT/scripts/fetch-singbox.sh" darwin "$GOARCH" "$SINGBOX_DIR"

APP=dist/AutoVPN.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.alsh.autovpn</string>
  <key>CFBundleName</key><string>AutoVPN</string>
  <key>CFBundleDisplayName</key><string>AutoVPN</string>
  <key>CFBundleExecutable</key><string>AutoVPN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.2</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST

cp .build/release/AutoVPN "$APP/Contents/MacOS/AutoVPN"
cp "$SINGBOX_DIR/sing-box" "$APP/Contents/MacOS/sing-box"
chmod +x "$APP/Contents/MacOS/sing-box"
if [[ -f "$SINGBOX_DIR/sing-box-LICENSE" ]]; then
  cp "$SINGBOX_DIR/sing-box-LICENSE" "$APP/Contents/Resources/sing-box-LICENSE"
fi
if [[ -f "$SINGBOX_DIR/sing-box.version" ]]; then
  cp "$SINGBOX_DIR/sing-box.version" "$APP/Contents/Resources/sing-box.version"
fi

codesign --force -s - "$APP/Contents/MacOS/sing-box"
codesign --force -s - "$APP"
echo "OK: $APP (sing-box bundled)"
