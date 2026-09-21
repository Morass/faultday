#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p build/Faultday.app/Contents/MacOS
cp .build/release/faultday build/Faultday.app/Contents/MacOS/faultday
cat > build/Faultday.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>faultday</string>
<key>CFBundleIdentifier</key><string>com.morass.faultday</string>
<key>CFBundleName</key><string>Faultday</string>
<key>CFBundleDisplayName</key><string>Faultday</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
