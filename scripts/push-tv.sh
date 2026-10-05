#!/bin/bash
# Build, sign with the free Personal Team, and install on the Apple TV. Re-run within 7 days.
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM="${LANTERNA_TEAM:-3ZZ8EU3NAV}"
DEVICE="${LANTERNA_TV:-Living Room Apple TV}"
LOG="$HOME/Library/Logs/lanterna-push-tv.log"
exec > >(tee -a "$LOG") 2>&1
echo "== $(date)"
xcodegen generate
xcodebuild -project Lanterna.xcodeproj -scheme Lanterna-tvOS -configuration Release -sdk appletvos \
  -derivedDataPath build/tv-dd -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build
APP=build/tv-dd/Build/Products/Release-appletvos/Lanterna.app
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "installed"
