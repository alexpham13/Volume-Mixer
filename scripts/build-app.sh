#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project 'Volume Mixer.xcodeproj' -scheme 'Volume Mixer' \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build build
app='build/Build/Products/Release/Volume Mixer.app'
/usr/libexec/PlistBuddy -c 'Print NSAudioCaptureUsageDescription' "$app/Contents/Info.plist"
codesign --verify --strict "$app"
echo "Built $PWD/$app"
