#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "Building QuotaDeck (release)..."
swift build -c release

APP_DIR="build/QuotaDeck.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp .build/release/QuotaDeck "$APP_DIR/MacOS/QuotaDeck"

cat << 'EOF' > "$APP_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>QuotaDeck</string>
    <key>CFBundleIdentifier</key>
    <string>com.quotadeck.app</string>
    <key>CFBundleName</key>
    <string>QuotaDeck</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>9</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF

chmod +x "$APP_DIR/MacOS/QuotaDeck"

# WidgetKit Extension Bundle
echo "Building Widget Extension via Xcode..."
xcodegen generate >/dev/null
xcodebuild -project QuotaDeck.xcodeproj -target QuotaDeckWidget -configuration Release CODE_SIGNING_ALLOWED=NO build >/dev/null

PLUGIN_DEST="$APP_DIR/PlugIns"
mkdir -p "$PLUGIN_DEST"
rm -rf "$PLUGIN_DEST/QuotaDeckWidget.appex"
cp -R build/Release/QuotaDeckWidget.appex "$PLUGIN_DEST/QuotaDeckWidget.appex"

# Code Signing
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}' || true)

if [ -n "$IDENTITY" ]; then
    echo "Signing with identity: $IDENTITY"
    codesign --force --options runtime --entitlements Sources/QuotaDeckWidget/QuotaDeckWidget.entitlements --sign "$IDENTITY" "build/QuotaDeck.app/Contents/PlugIns/QuotaDeckWidget.appex"
    codesign --force --options runtime --entitlements Sources/QuotaDeckApp/QuotaDeck.entitlements --sign "$IDENTITY" "build/QuotaDeck.app"
else
    echo "Signing ad-hoc..."
    codesign --force --sign - --entitlements Sources/QuotaDeckWidget/QuotaDeckWidget.entitlements "build/QuotaDeck.app/Contents/PlugIns/QuotaDeckWidget.appex"
    codesign --force --sign - --entitlements Sources/QuotaDeckApp/QuotaDeck.entitlements "build/QuotaDeck.app"
fi


echo "Successfully created build/QuotaDeck.app with WidgetKit extension"
