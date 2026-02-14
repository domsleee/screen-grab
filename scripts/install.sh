#!/bin/bash
set -e

cd "$(dirname "$0")/.."

./scripts/build.sh

echo "Installing to /Applications..."
rm -rf /Applications/ScreenGrab.app
cp -r ScreenGrab.app /Applications/

echo "Done! Launch from /Applications or Spotlight."
