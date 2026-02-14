#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Building ScreenGrab..."
swift build -c release

echo "Creating app bundle..."
cp .build/release/ScreenGrab ScreenGrab.app/Contents/MacOS/

# Inject git commit hash and date into Info.plist
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_DATE=$(git log -1 --format=%ai 2>/dev/null | cut -d' ' -f1 || echo "unknown")
PLIST="ScreenGrab.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :GitCommitHash" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string $GIT_HASH" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :GitCommitDate" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GitCommitDate string $GIT_DATE" "$PLIST"

echo "Signing..."
codesign --force --deep --sign "ScreenGrab Dev" ScreenGrab.app

echo "Done! Run with: open ScreenGrab.app"
