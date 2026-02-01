#!/bin/bash
set -e

cd "$(dirname "$0")/.."

./scripts/build.sh

echo "Installing to /Applications..."
cp -r ScreenGrab.app /Applications/

echo "Done! Launch from /Applications or Spotlight."
