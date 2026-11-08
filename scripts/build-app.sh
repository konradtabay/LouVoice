#!/bin/bash
# Build LouVoice.app from the SwiftPM package (Command Line Tools are enough; D19).
# macOS only shows the Motion permission prompt for a real bundle with NSMotionUsageDescription,
# so a bare `swift run` binary can't receive AirPods motion.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product LouVoice
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LouVoice"

APP="build/LouVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LouVoice"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Geist Sans + Geist Serif Square, the landing page fonts (registered at launch by LV.registerFonts).
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# App icon: the website favicon mark on a cream rounded square (Resources/AppIcon.icns).
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for running on this Mac (D20). Testers need "Open Anyway" once.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:  open $APP"
