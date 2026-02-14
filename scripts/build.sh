#!/bin/bash
set -e

cd "$(dirname "$0")/.."

# Parse flags
UNIVERSAL=false
SIGN_IDENTITY="ScreenGrab Dev"
VERSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --universal)
            UNIVERSAL=true
            shift
            ;;
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --version)
            VERSION_OVERRIDE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: build.sh [--universal] [--sign <identity>] [--version <ver>]"
            exit 1
            ;;
    esac
done

echo "Building ScreenGrab..."
if [ "$UNIVERSAL" = true ]; then
    swift build -c release --arch arm64 --arch x86_64
    BUILD_BIN=".build/apple/Products/Release/ScreenGrab"
else
    swift build -c release
    BUILD_BIN=".build/release/ScreenGrab"
fi

echo "Creating app bundle..."
mkdir -p ScreenGrab.app/Contents/MacOS
cp "$BUILD_BIN" ScreenGrab.app/Contents/MacOS/
cp ScreenGrab/Resources/Info.plist ScreenGrab.app/Contents/Info.plist

# Inject git commit hash and date into Info.plist
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_DATE=$(git log -1 --format=%ai 2>/dev/null | cut -d' ' -f1 || echo "unknown")
PLIST="ScreenGrab.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :GitCommitHash" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string $GIT_HASH" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :GitCommitDate" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GitCommitDate string $GIT_DATE" "$PLIST"

# For release builds (--version), keep the release bundle ID.
# For dev builds, use a separate bundle ID so macOS doesn't confuse permissions.
if [ -n "$VERSION_OVERRIDE" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION_OVERRIDE" "$PLIST"
    # Strip leading 'v' and any suffix for CFBundleVersion (e.g. v0.1.0-Beta -> 0.1.0)
    BUNDLE_VERSION=$(echo "$VERSION_OVERRIDE" | sed 's/^v//' | sed 's/-.*//')
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$PLIST"
else
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.screengrab.app.dev" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ScreenGrab Dev" "$PLIST"
fi

echo "Signing with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" ScreenGrab.app

echo "Done! Run with: open ScreenGrab.app"
