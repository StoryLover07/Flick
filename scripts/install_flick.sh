#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="/private/tmp/FlickDerivedData"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Debug/Flick.app"
INSTALLED_APP="/Applications/Flick.app"
LEGACY_INSTALLED_APP="/Applications/Flick Arrange.app"
ENTITLEMENTS="$DERIVED_DATA_DIR/Build/Intermediates.noindex/Flick.build/Debug/Flick.build/Flick.app.xcent"

cd "$ROOT_DIR"

xcodebuild \
  -project Flick.xcodeproj \
  -scheme "Flick" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

# Keep the designated requirement stable across local builds so macOS TCC
# can associate Accessibility permission with the app identity instead of a
# changing ad-hoc cdhash.
/usr/bin/codesign \
  --force \
  --sign - \
  --requirements '=designated => identifier "com.jihoonchoi.FlickArrange"' \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  --generate-entitlement-der \
  "$BUILT_APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

osascript -e 'tell application id "com.jihoonchoi.FlickArrange" to quit' >/dev/null 2>&1 || true
/bin/rm -rf "$INSTALLED_APP"
/bin/rm -rf "$LEGACY_INSTALLED_APP"
/usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
open -a "$INSTALLED_APP" >/dev/null 2>&1 || true
