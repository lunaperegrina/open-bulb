#!/bin/bash
# Builds OpenBulb.app (release) and signs it ad-hoc.
#   ./Scripts/build.sh [--install]   → also copies to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
swift build -c $CONFIG --product OpenBulb

APP_NAME="OpenBulb"
BUNDLE_ID="com.lunaperegrina.openbulb"
BUILD_DIR=".build/$CONFIG/$(swift build -c $CONFIG --show-bin-path 2>/dev/null | tail -1)"
BIN="$BUILD_DIR/OpenBulb"

if [[ ! -x "$BIN" ]]; then
  # fallback: locate the binary directly
  BIN="$(find .build -type f -name OpenBulb -perm +111 | head -1)"
fi

STAGE="build/app"
rm -rf "$STAGE"
mkdir -p "$STAGE/$APP_NAME.app/Contents/MacOS"
mkdir -p "$STAGE/$APP_NAME.app/Contents/Resources"

cp "$BIN" "$STAGE/$APP_NAME.app/Contents/MacOS/$APP_NAME"

cat > "$STAGE/$APP_NAME.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Open Bulb</string>
    <key>CFBundleDisplayName</key>       <string>Open Bulb</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>O Open Bulb conversa com a lâmpada Elgin diretamente na sua rede Wi-Fi.</string>
    <key>NSLocalNetworkBonjourServices</key>
    <array><string>_services._dns-sd._udp</string></array>
</dict>
</plist>
PLIST

# ad-hoc signature (stable identity for Keychain + SMAppService)
codesign --force --sign - "$STAGE/$APP_NAME.app"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    rm -rf "$DEST"
    cp -R "$STAGE/$APP_NAME.app" "$DEST"
    codesign --force --sign - "$DEST"
    echo "installed: $DEST"
fi

echo "built: $PWD/$STAGE/$APP_NAME.app"
