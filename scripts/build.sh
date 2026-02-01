#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Building ScreenGrab..."
swift build -c release

echo "Creating app bundle..."
cp .build/release/ScreenGrab ScreenGrab.app/Contents/MacOS/

echo "Signing..."
codesign --force --deep --sign "ScreenGrab Dev" ScreenGrab.app

echo "Done! Run with: open ScreenGrab.app"
