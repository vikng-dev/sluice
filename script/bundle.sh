#!/bin/bash
# Builds a universal Sluice.app into dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -nE 's/.*version = "([^"]+)".*/\1/p' Sources/Core/Version.swift)
app=dist/Sluice.app

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf dist
mkdir -p "$app/Contents/MacOS"
cp "$bin/SluiceApp" "$app/Contents/MacOS/Sluice"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.vikng.sluice</string>
    <key>CFBundleName</key><string>Sluice</string>
    <key>CFBundleExecutable</key><string>Sluice</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
echo "$app ($version)"
