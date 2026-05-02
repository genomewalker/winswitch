#!/usr/bin/env bash
set -euo pipefail

APP="WinSwitch"
OUT="$APP.app"
BINARY="$OUT/Contents/MacOS/$APP"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "Compiling..."
swiftc main.swift \
    -O \
    -framework AppKit \
    -o "$BINARY"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>    <string>com.local.winswitch</string>
    <key>CFBundleName</key>          <string>WinSwitch</string>
    <key>CFBundleExecutable</key>    <string>$APP</string>
    <key>CFBundleVersion</key>       <string>1.0</string>
    <key>LSUIElement</key>           <true/>
    <key>NSPrincipalClass</key>      <string>NSApplication</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>WinSwitch needs Accessibility access to read window titles and switch focus.</string>
</dict>
</plist>
EOF

echo "Built: $(pwd)/$OUT"
echo "Run:   open $OUT"
echo ""
echo "On first launch, grant Accessibility in:"
echo "  System Settings → Privacy & Security → Accessibility"
